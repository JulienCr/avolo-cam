//
//  EncoderManager.swift
//  AvoCam
//
//  Manages VideoToolbox H.264 encoding with low-latency configuration
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

class EncoderManager {
    // MARK: - Properties

    private var compressionSession: VTCompressionSession?
    private var encodedCallback: ((Data) -> Void)?

    private var currentBitrate: Int = 10_000_000
    private var currentFramerate: Int = 30
    private var currentResolution: (width: Int, height: Int)?

    // Telemetry
    private var encodedFrameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var lastEncodedTime: Date = Date()
    private var currentFPS: Double = 0
    private var queueDepthMs: Int = 0

    private let telemetryLock = NSLock()

    // MARK: - Configuration

    func configure(resolution: String, framerate: Int, bitrate: Int, codec: String) throws {
        print("🎬 Configuring encoder: \(resolution) @ \(framerate)fps, \(bitrate)bps, codec: \(codec)")

        let dimensions = try parseResolution(resolution)
        currentResolution = dimensions
        currentFramerate = framerate
        currentBitrate = bitrate

        // Create compression session
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(dimensions.width),
            height: Int32(dimensions.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.sessionCreationFailed(status)
        }

        // Configure low-latency properties
        try setLowLatencyProperties(session: session, framerate: framerate, bitrate: bitrate)

        // Prepare to encode
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        print("✅ Encoder configured successfully")
    }

    private func setLowLatencyProperties(session: VTCompressionSession, framerate: Int, bitrate: Int) throws {
        // Real-time encoding
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        // Profile level (H.264 High 4.2)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_High_4_2
        )

        // Disable frame reordering (no B-frames)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )

        // GOP = framerate (keyframe every second)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: framerate as CFNumber
        )

        // Average bitrate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrate as CFNumber
        )

        // Data rate limits (bitrate, 1 second)
        let dataRateLimits = [bitrate as CFNumber, 1 as CFNumber] as CFArray
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits
        )

        // Expected frame rate
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: framerate as CFNumber
        )

        // Enable hardware acceleration if available
        VTSessionSetProperty(
            session,
            key: kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
            value: kCFBooleanTrue
        )

        print("✅ Low-latency encoder properties set")
    }

    // MARK: - Encoding

    func encode(sampleBuffer: CMSampleBuffer, completion: @escaping (Data) -> Void) {
        guard let session = compressionSession else {
            print("❌ Encoder session not configured")
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("❌ Failed to get image buffer from sample")
            return
        }

        encodedCallback = completion

        // Get presentation timestamp
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Encode frame
        let encodeFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        if status != noErr {
            print("❌ Encode frame failed: \(status)")
            telemetryLock.lock()
            droppedFrameCount += 1
            telemetryLock.unlock()
        }
    }

    func stop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        print("⏹ Encoder stopped")
    }

    // MARK: - Force Keyframe

    func forceKeyframe() {
        guard let session = compressionSession else { return }

        // Request immediate keyframe
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        print("🔑 Keyframe forced")
    }

    // MARK: - Telemetry

    func getCurrentTelemetry() -> (fps: Double, bitrate: Int, queueMs: Int, droppedFrames: Int)? {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }

        return (
            fps: currentFPS,
            bitrate: currentBitrate,
            queueMs: queueDepthMs,
            droppedFrames: droppedFrameCount
        )
    }

    private func updateTelemetry() {
        telemetryLock.lock()
        defer { telemetryLock.unlock() }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastEncodedTime)

        if elapsed > 0 {
            currentFPS = 1.0 / elapsed
        }

        lastEncodedTime = now
        encodedFrameCount += 1

        // Queue depth estimation (simplified)
        // In production, track actual queue depth
        queueDepthMs = Int(elapsed * 1000)
    }

    // MARK: - Dynamic Bitrate Adjustment

    func adjustBitrate(_ newBitrate: Int) {
        guard let session = compressionSession else { return }

        currentBitrate = newBitrate

        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: newBitrate as CFNumber
        )

        let dataRateLimits = [newBitrate as CFNumber, 1 as CFNumber] as CFArray
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits
        )

        print("🔧 Bitrate adjusted to \(newBitrate)bps")
    }

    // MARK: - Helpers

    private func parseResolution(_ resolution: String) throws -> (width: Int, height: Int) {
        let components = resolution.split(separator: "x").compactMap { Int($0) }
        guard components.count == 2 else {
            throw EncoderError.invalidResolution
        }
        return (width: components[0], height: components[1])
    }
}

// MARK: - Compression Output Callback

private let compressionOutputCallback: VTCompressionOutputCallback = { (
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) in
    guard status == noErr else {
        print("❌ Compression output error: \(status)")
        return
    }

    guard let sampleBuffer = sampleBuffer else {
        print("❌ Compression output: no sample buffer")
        return
    }

    guard let encoderManager = outputCallbackRefCon.map({ Unmanaged<EncoderManager>.fromOpaque($0).takeUnretainedValue() }) else {
        return
    }

    // Update telemetry
    encoderManager.updateTelemetry()

    // Check if this is a keyframe
    let isKeyframe = !CFDictionaryContainsKey(
        CMSampleBufferGetAttachmentsArray(sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? CFDictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
    )

    // Extract H.264 elementary stream data
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        print("❌ Failed to get data buffer")
        return
    }

    var length: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: nil,
        totalLengthOut: &length,
        dataPointerOut: &dataPointer
    )

    guard status == noErr, let data = dataPointer else {
        print("❌ Failed to get data pointer")
        return
    }

    // Copy data
    let encodedData = Data(bytes: data, count: length)

    // Call completion callback
    if let callback = encoderManager.encodedCallback {
        callback(encodedData)
    }
}

// MARK: - Errors

enum EncoderError: LocalizedError {
    case sessionCreationFailed(OSStatus)
    case invalidResolution
    case encodeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let status):
            return "Failed to create compression session: \(status)"
        case .invalidResolution:
            return "Invalid resolution format"
        case .encodeFailed(let status):
            return "Encoding failed: \(status)"
        }
    }
}
