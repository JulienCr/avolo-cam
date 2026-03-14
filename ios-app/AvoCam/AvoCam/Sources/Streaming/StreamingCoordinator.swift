//
//  StreamingCoordinator.swift
//  AvoCam
//
//  Orchestrates the video streaming pipeline
//

import Foundation
import AVFoundation

/// Thread-safe counter for debug frame logging in capture callbacks.
/// Uses `os_unfair_lock` for minimal overhead in the real-time capture path.
private final class FrameCounter: @unchecked Sendable {
    private var _value: Int = 0
    private var _lock = os_unfair_lock()

    /// Atomically increments the counter and returns the new value.
    func increment() -> Int {
        os_unfair_lock_lock(&_lock)
        _value += 1
        let v = _value
        os_unfair_lock_unlock(&_lock)
        return v
    }

    /// Resets the counter to zero.
    func reset() {
        os_unfair_lock_lock(&_lock)
        _value = 0
        os_unfair_lock_unlock(&_lock)
    }
}

/// Actor that coordinates the streaming pipeline between capture and output (NDI, SRT, or Flash)
actor StreamingCoordinator: StreamingService {
    // MARK: - Properties

    private(set) var isStreaming: Bool = false
    private var currentMode: StreamingMode = .ndi

    private let captureManager: CaptureManager
    private let ndiManager: NDIManager
    private let srtManager: SRTManager
    private let flashManager: FlashManager
    private var tallyPoller: NDITallyPoller?

    /// Debug frame counter for Flash mode logging (replaces leaked UnsafeMutablePointer)
    private let flashFrameCounter = FrameCounter()

    // MARK: - Initialization

    init(captureManager: CaptureManager, ndiManager: NDIManager, srtManager: SRTManager, flashManager: FlashManager) {
        self.captureManager = captureManager
        self.ndiManager = ndiManager
        self.srtManager = srtManager
        self.flashManager = flashManager
    }

    func setTallyPoller(_ poller: NDITallyPoller) {
        self.tallyPoller = poller
    }

    // MARK: - StreamingService Protocol

    nonisolated var isCurrentlyStreaming: Bool {
        get async { await isStreaming }
    }

    func startStreaming(request: StreamStartRequest) async throws {
        guard !isStreaming else {
            throw AVOCamError.alreadyStreaming
        }

        // Determine streaming mode
        let mode = request.streamingMode ?? .ndi
        currentMode = mode

        print("▶️ Starting \(mode.rawValue.uppercased()) stream: \(request.resolution) @ \(request.framerate)fps, \(request.bitrate)bps")

        // 1. Configure capture
        try await captureManager.configure(
            resolution: request.resolution,
            framerate: request.framerate
        )

        let resolution = Resolution.parseWithDefault(request.resolution)
        let width = resolution.width
        let height = resolution.height

        // 2. Start appropriate streaming backend
        switch mode {
        case .ndi:
            try ndiManager.start(
                width: width,
                height: height,
                fps: request.framerate
            )

            // 3. Start capture with frame callback that feeds NDI
            try await captureManager.startCapture { [ndiManager] sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return
                }
                ndiManager.send(pixelBuffer: pixelBuffer)
            }

            // 4. Start tally poller for torch control (NDI only)
            tallyPoller?.start()

        case .srt:
            // Configure SRT manager
            let srtConfig = SRTConfiguration.from(request: request)
            try await srtManager.start(config: srtConfig.toManagerConfiguration())

            // Start capture with frame callback that feeds SRT encoder
            try await captureManager.startCapture { [srtManager] sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    return
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let duration = CMSampleBufferGetDuration(sampleBuffer)

                Task {
                    await srtManager.send(pixelBuffer: pixelBuffer, timestamp: timestamp, duration: duration)
                }
            }

        case .flash:
            guard let destHost = request.flashDestinationHost else {
                throw AVOCamError.invalidConfiguration("Flash mode requires destination host")
            }

            let flashConfig = FlashManager.Configuration(
                destinationHost: destHost,
                destinationPort: UInt16(request.flashDestinationPort ?? 5000),
                width: width,
                height: height,
                fps: request.framerate,
                bitrate: request.bitrate,
                gopSize: request.srtGopSize ?? request.framerate  // Reuse GOP setting
            )

            try await flashManager.start(config: flashConfig)

            // Reset debug frame counter for this streaming session
            flashFrameCounter.reset()

            // Start capture with frame callback that feeds Flash encoder
            let counter = flashFrameCounter
            try await captureManager.startCapture { [flashManager] sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    print("⚠️ FLASH: No pixel buffer in sample")
                    return
                }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let duration = CMSampleBufferGetDuration(sampleBuffer)

                // Debug logging every 30 frames
                let count = counter.increment()
                if count % 30 == 1 {
                    print("📹 FLASH: Sending frame \(count) to encoder")
                }

                Task {
                    await flashManager.send(pixelBuffer: pixelBuffer, timestamp: timestamp, duration: duration)
                }
            }
        }

        isStreaming = true

        print("✅ \(mode.rawValue.uppercased()) streaming started successfully")
    }

    func stopStreaming() async {
        guard isStreaming else { return }

        print("⏹ Stopping \(currentMode.rawValue.uppercased()) stream")

        // Stop in reverse order based on current mode
        switch currentMode {
        case .ndi:
            tallyPoller?.stop()
            await captureManager.stopCapture()
            ndiManager.stop()

        case .srt:
            await captureManager.stopCapture()
            await srtManager.stop()

        case .flash:
            await captureManager.stopCapture()
            await flashManager.stop()
        }

        isStreaming = false

        print("✅ Streaming stopped")
    }

    // MARK: - NDI Status

    func getConnectionCount() -> Int {
        return ndiManager.getConnectionCount()
    }

    func getTallyState() -> (program: Bool, preview: Bool) {
        return ndiManager.getTallyState()
    }

    func getTelemetryStats() async -> (fps: Double, sentFrames: Int64, droppedFrames: Int64) {
        switch currentMode {
        case .ndi:
            return ndiManager.getTelemetryStats()
        case .srt:
            return await srtManager.getStats()
        case .flash:
            return await flashManager.getStats()
        }
    }

    func getCurrentStreamingMode() -> StreamingMode {
        return currentMode
    }

}
