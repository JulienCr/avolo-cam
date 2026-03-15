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
            Log.encoder.warning("Encoding callback error: \(status)")
        }
        return
    }

    guard let refCon = outputCallbackRefCon else {
        Log.encoder.warning("Missing refCon in encoding callback")
        return
    }

    // Extract encoder instance without consuming the retain.
    // The refcon holds a +1 retain via passRetained; it is balanced
    // by an explicit release in stop()/configure()/deinit.
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
    encoder.handleEncodedFrame(sampleBuffer)
}

/// Hardware-accelerated H.264 encoder with low-latency configuration
actor H264Encoder {
    // MARK: - Properties

    private var compressionSession: VTCompressionSession?
    private var width: Int32 = 1920
    private var height: Int32 = 1080
    private var fps: Int32 = 25
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
        Log.encoder.info("Configuring H264Encoder: \(width)x\(height) @ \(fps)fps, \(bitrate)bps, GOP=\(gopSize)")

        // Store parameters
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = Int32(fps)
        self.bitrate = Int32(bitrate)
        self.gopSize = Int32(gopSize)

        // Invalidate existing session if any, and release the retained refcon
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            // Balance the passRetained(self) from the previous session creation
            Unmanaged.passUnretained(self).release()
        }

        // Create compression session with callback bridge.
        // We pass an unretained pointer during creation, then add a +1 retain
        // only after confirming the session was created successfully.
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

        // Use passUnretained for the create call; we add the +1 retain below
        // only if the session is created successfully.
        let refconPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: refconPtr,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw H264EncoderError.sessionCreationFailed(status)
        }

        // Session created successfully. Add +1 retain so self stays alive
        // as long as the compression session's refcon can invoke the callback.
        // This retain is balanced by the release in invalidateSession()/configure().
        _ = Unmanaged.passRetained(self)

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

        Log.encoder.info("H264Encoder configured successfully (hardware-accelerated)")
    }

    /// Set a compression session property
    private func setProperty<T>(session: VTCompressionSession, key: CFString, value: T) throws {
        let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        guard status == noErr else {
            Log.encoder.warning("Failed to set property \(key): \(status)")
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
            Log.encoder.warning("Encoder not configured")
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
            Log.encoder.warning("Encode frame failed: \(status)")
        }
    }

    /// Force the next frame to be a keyframe (IDR)
    func forceKeyframe() async {
        guard compressionSession != nil else { return }

        // Note: To force a keyframe, pass properties in encode() frameProperties parameter
        // For future implementation: store a flag and use it in the next encode() call
        Log.encoder.debug("Keyframe requested (to be implemented in encode)")
    }

    // MARK: - Lifecycle

    /// Stop encoding and clean up resources
    func stop() {
        invalidateSession()
    }

    /// Invalidate the compression session and release the retained self reference.
    /// This is separated so it can be called from both stop() and deinit.
    private func invalidateSession() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
            // Balance the passRetained(self) from session creation.
            // After this release, the session's refcon no longer prevents deallocation.
            Unmanaged.passUnretained(self).release()
            Log.encoder.info("H264Encoder stopped")
        }
    }

    deinit {
        // Safety net: if stop() was never called, the passRetained refcon keeps us alive,
        // so reaching deinit means the session was already invalidated (or never created).
        // However, if someone manually nil'd the strong reference after invalidation
        // but before stop(), we still guard here.
        if compressionSession != nil {
            Log.encoder.warning("H264Encoder deinit: session still active, invalidating")
            // VTCompressionSessionInvalidate is synchronous and safe to call from deinit.
            VTCompressionSessionInvalidate(compressionSession!)
            compressionSession = nil
            // Note: we do NOT call release() here because if deinit is running,
            // ARC has already determined the retain count reached zero, meaning
            // the passRetained was already balanced (or this is the final release).
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
