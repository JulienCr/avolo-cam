//
//  StreamingCoordinator.swift
//  AvoCam
//
//  Orchestrates the video streaming pipeline
//

import Foundation
import AVFoundation

/// Actor that coordinates the streaming pipeline between capture and NDI output
actor StreamingCoordinator: StreamingService {
    // MARK: - Properties

    private(set) var isStreaming: Bool = false

    private let captureManager: CaptureManager
    private let ndiManager: NDIManager
    private var tallyPoller: NDITallyPoller?

    // MARK: - Initialization

    init(captureManager: CaptureManager, ndiManager: NDIManager) {
        self.captureManager = captureManager
        self.ndiManager = ndiManager
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

        print("▶️ Starting stream: \(request.resolution) @ \(request.framerate)fps, \(request.bitrate)bps")

        // 1. Configure capture
        try await captureManager.configure(
            resolution: request.resolution,
            framerate: request.framerate
        )

        // 2. Start NDI sender
        try ndiManager.start(
            width: parseWidth(from: request.resolution),
            height: parseHeight(from: request.resolution),
            fps: request.framerate
        )

        // 3. Start capture with frame callback that feeds NDI
        try await captureManager.startCapture { [ndiManager] sampleBuffer in
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            ndiManager.send(pixelBuffer: pixelBuffer)
        }

        isStreaming = true

        // 4. Start tally poller for torch control
        tallyPoller?.start()

        print("✅ Streaming started successfully")
    }

    func stopStreaming() async {
        guard isStreaming else { return }

        print("⏹ Stopping stream")

        // Stop in reverse order
        tallyPoller?.stop()
        await captureManager.stopCapture()
        ndiManager.stop()

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

    func getTelemetryStats() -> (fps: Double, sentFrames: Int64, droppedFrames: Int64) {
        return ndiManager.getTelemetryStats()
    }

    // MARK: - Private Helpers

    private func parseWidth(from resolution: String) -> Int {
        let components = resolution.split(separator: "x")
        return Int(components.first ?? "1920") ?? 1920
    }

    private func parseHeight(from resolution: String) -> Int {
        let components = resolution.split(separator: "x")
        return Int(components.last ?? "1080") ?? 1080
    }
}
