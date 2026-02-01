//
//  H264Encoder.swift
//  AvoCam
//
//  Hardware-accelerated H.264 encoder using VideoToolbox
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Errors that can occur during H.264 encoding
enum H264EncoderError: Error {
    case sessionCreationFailed(OSStatus)
    case propertySetFailed(OSStatus)
    case encodeFrameFailed(OSStatus)
    case invalidConfiguration
}

// MARK: - C Callback Bridge (must be at file scope, not actor-isolated)

/// C function callback for VideoToolbox compression session
@preconcurrency
nonisolated private func encodingOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer = sampleBuffer else {
        if status != noErr {
            print("⚠️ Encoding callback error: \(status)")
        }
        return
    }

    guard let refCon = outputCallbackRefCon else {
        print("⚠️ Missing refCon in encoding callback")
        return
    }

    // Extract encoder instance and call handler
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(sampleBuffer)
}

/// Hardware-accelerated H.264 encoder with low-latency configuration
actor H264Encoder {
    // MARK: - Properties

    private var compressionSession: VTCompressionSession?
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var fps: Int32 = 30
    private var bitrate: Int32 = 10_000_000
    private var gopSize: Int32 = 3  // Lower default for low-latency streaming

    typealias EncodedFrameCallback = @Sendable (CMSampleBuffer) -> Void
    private var onEncodedFrame: EncodedFrameCallback?

    // MARK: - Configuration

    /// Configure the encoder with video parameters
    /// - Parameters:
    ///   - width: Video width in pixels
    ///   - height: Video height in pixels
    ///   - fps: Target frame rate
    ///   - bitrate: Target bitrate in bits per second
    ///   - gopSize: Keyframe interval in frames (default: 3 for low latency)
    func configure(width: Int, height: Int, fps: Int, bitrate: Int, gopSize: Int = 3) throws {
        print("🎬 Configuring H264Encoder: \(width)x\(height) @ \(fps)fps, \(bitrate)bps, GOP=\(gopSize)")

        // Store parameters
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = Int32(fps)
        self.bitrate = Int32(bitrate)
        self.gopSize = Int32(gopSize)

        // Invalidate existing session if any
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        // Create compression session with callback bridge
        var session: VTCompressionSession?

        // Hardware encoder specification (iOS 17.4+)
        // On older iOS, VideoToolbox will use hardware encoding automatically if available
        let encoderSpecification: CFDictionary?
        if #available(iOS 17.4, *) {
            encoderSpecification = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary
        } else {
            // Let VideoToolbox choose the best encoder (usually hardware)
            encoderSpecification = nil
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw H264EncoderError.sessionCreationFailed(status)
        }

        compressionSession = session

        // Configure low-latency properties
        try setProperty(session: session, key: kVTCompressionPropertyKey_RealTime, value: true as CFBoolean)
        try setProperty(session: session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        try setProperty(session: session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false as CFBoolean)
        // GOP (keyframe interval) - configurable for latency vs bandwidth trade-off
        // Shorter GOP = more keyframes = faster decoder sync = lower latency (~100ms at GOP=3, 30fps)
        // Trade-off: ~20-30% higher bitrate with shorter GOP
        try setProperty(session: session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: self.gopSize as CFNumber)
        try setProperty(session: session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(self.gopSize) / Double(self.fps) as CFNumber)
        try setProperty(session: session, key: kVTCompressionPropertyKey_AverageBitRate, value: self.bitrate as CFNumber)
        try setProperty(session: session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: self.fps as CFNumber)

        // Data rate limits (bitrate, duration in seconds)
        let dataRateLimits: CFArray = [self.bitrate as CFNumber, 1 as CFNumber] as CFArray
        try setProperty(session: session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)

        // Prepare to encode
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            throw H264EncoderError.sessionCreationFailed(prepareStatus)
        }

        print("✅ H264Encoder configured successfully (hardware-accelerated)")
    }

    /// Set a compression session property
    private func setProperty<T>(session: VTCompressionSession, key: CFString, value: T) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        guard status == noErr else {
            print("⚠️ Failed to set property \(key): \(status)")
            throw H264EncoderError.propertySetFailed(status)
        }
    }

    // MARK: - Callback Management

    /// Set the callback for encoded frames
    func setCallback(_ callback: @escaping EncodedFrameCallback) {
        onEncodedFrame = callback
    }

    // MARK: - Encoding

    /// Encode a pixel buffer
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to encode
    ///   - presentationTime: Presentation timestamp
    ///   - duration: Frame duration
    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime) {
        guard let session = compressionSession else {
            print("⚠️ Encoder not configured")
            return
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            print("⚠️ Encode frame failed: \(status)")
        }
    }

    /// Force the next frame to be a keyframe (IDR)
    func forceKeyframe() async {
        guard compressionSession != nil else { return }

        // Note: To force a keyframe, pass properties in encode() frameProperties parameter
        // For future implementation: store a flag and use it in the next encode() call
        print("🔑 Keyframe requested (to be implemented in encode)")
    }

    // MARK: - Lifecycle

    /// Stop encoding and clean up resources
    func stop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            print("⏹ H264Encoder stopped")
        }
    }

    // MARK: - Internal Callback Handler

    /// Called by the C callback bridge
    nonisolated func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        Task {
            await deliverEncodedFrame(sampleBuffer)
        }
    }

    private func deliverEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        onEncodedFrame?(sampleBuffer)
    }
}
