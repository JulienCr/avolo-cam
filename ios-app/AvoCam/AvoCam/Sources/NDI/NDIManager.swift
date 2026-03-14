//
//  NDIManager.swift
//  AvoCam
//
//  Manages NDI video transmission via NDI SDK
//

import Foundation
import CoreMedia
import CoreVideo
import os.signpost

class NDIManager {
    // MARK: - Properties

    private let alias: String

    // PERF: Feature flags for optimization rollback
    private let enableBackpressure = true
    private let enableDedicatedQueue = true
    private let enableReducedAllocation = true
    private let enableSignposts = true

    // PERF: Dedicated NDI send queue (off capture thread)
    private let ndiQueue = DispatchQueue(
        label: "com.avocam.ndi.send",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )

    // PERF: Backpressure control (max 3 frames in-flight to NDI)
    private let ndiSemaphore = DispatchSemaphore(value: 3)

    // PERF: Thread-safe stats counters using OSAllocatedUnfairLock (replaces deprecated OSAtomicIncrement64)
    private let statsLock = OSAllocatedUnfairLock(uncheckedState: (dropped: Int64(0), sent: Int64(0)))

    /// Thread-safe lock protecting all mutable state accessed from multiple threads.
    /// Protected fields: ndiSender, isActive, currentFPS, ndiVideoFrame,
    /// frameCount, lastLogTime, frameStatsCounter, frameStatsLastPrint
    private let stateLock = OSAllocatedUnfairLock(uncheckedState: NDIState())

    // PERF: os_signpost for latency tracking
    private let perfLog = OSLog(subsystem: "com.avocam.ndi", category: .pointsOfInterest)
    private lazy var sendSignpostID = OSSignpostID(log: perfLog)

    // PERF: Cached mach_timebase_info (constant for process lifetime)
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // MARK: - State Container

    /// All mutable state that requires synchronization, bundled into a single struct
    /// so it can be protected by a single `OSAllocatedUnfairLock`.
    private struct NDIState {
        var ndiSender: NDIlib_send_instance_t?
        var isActive: Bool = false
        var currentFPS: Int = 30
        var ndiVideoFrame = NDIlib_video_frame_v2_t()
        var frameStatsCounter: Int = 0
        var frameStatsLastPrint: UInt64 = 0
    }

    // MARK: - Initialization

    init(alias: String) {
        self.alias = alias
        print("📡 NDI Manager initialized with alias: \(alias)")

        // Initialize NDI library
        if !NDIlib_initialize() {
            print("❌ Failed to initialize NDI library")
        } else {
            print("✅ NDI library initialized")
        }
    }

    deinit {
        stop()
        NDIlib_destroy()
    }

    // MARK: - NDI Control

    func start(width: Int = 1920, height: Int = 1080, fps: Int = 25) throws {
        let alreadyActive = stateLock.withLock { $0.isActive }
        guard !alreadyActive else {
            print("⚠️ NDI sender already active")
            return
        }

        // Create NDI sender
        // Note: alias already has AVOLO-CAM- prefix from AppCoordinator
        let senderName = alias
        var newSender: NDIlib_send_instance_t?

        var sendSettings = NDIlib_send_create_t()
        senderName.withCString { namePtr in
            sendSettings.p_ndi_name = namePtr
            sendSettings.p_groups = nil
            sendSettings.clock_video = true
            sendSettings.clock_audio = false

            newSender = NDIlib_send_create(&sendSettings)
        }

        guard let sender = newSender else {
            throw NSError(
                domain: "NDIManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create NDI sender"]
            )
        }

        stateLock.withLock { state in
            state.ndiSender = sender
            state.isActive = true
            state.currentFPS = fps

            // PERF: Pre-initialize reusable frame struct
            if enableReducedAllocation {
                state.ndiVideoFrame = NDIlib_video_frame_v2_t()
                state.ndiVideoFrame.frame_rate_N = Int32(fps * 1000)
                state.ndiVideoFrame.frame_rate_D = 1000
                state.ndiVideoFrame.picture_aspect_ratio = Float(width) / Float(height)
                state.ndiVideoFrame.frame_format_type = NDIlib_frame_format_type_progressive
                state.frameStatsCounter = 0
                state.frameStatsLastPrint = 0
            }
        }

        if enableReducedAllocation {
            print("✅ PERF: NDI frame struct pre-initialized")
        }

        print("✅ NDI sender started: \(senderName) (\(width)x\(height)@\(fps)fps)")
    }

    func stop() {
        let sender = stateLock.withLock { state -> NDIlib_send_instance_t? in
            guard state.isActive else { return nil }
            let s = state.ndiSender
            state.isActive = false
            state.ndiSender = nil
            return s
        }

        if let sender = sender {
            NDIlib_send_destroy(sender)
            print("⏹ NDI sender stopped")
        }
    }

    // MARK: - Send Video Frame

    /// PERF: Optimized frame send with backpressure, dedicated queue, and zero-alloc stats
    func send(pixelBuffer: CVPixelBuffer) {
        // Snapshot sender, frame template, and stats in a single lock acquisition
        let snapshot = stateLock.withLock { state -> (sender: NDIlib_send_instance_t, frameTemplate: NDIlib_video_frame_v2_t, fps: Int)? in
            guard state.isActive, let sender = state.ndiSender else { return nil }
            return (sender, state.ndiVideoFrame, state.currentFPS)
        }
        guard let snapshot = snapshot else { return }
        let sender = snapshot.sender

        // PERF: Backpressure - drop frame if NDI queue is full (prevents latency buildup)
        if enableBackpressure {
            let acquired = ndiSemaphore.wait(timeout: .now())
            if acquired == .timedOut {
                // PERF: Single lock acquisition for increment + read
                let dropped = statsLock.withLock { state -> Int64 in
                    state.dropped += 1
                    return state.dropped
                }
                // Log every 30 drops to avoid spam
                if dropped % 30 == 1 {
                    print("⚠️ NDI backpressure: dropped \(dropped) frames total")
                }
                return
            }
        }

        // PERF: Send on dedicated queue (off capture thread, 8% CPU reduction)
        if enableDedicatedQueue {
            // Capture backpressure state and semaphore to avoid leak if self is deallocated
            let backpressureEnabled = enableBackpressure
            let semaphore = ndiSemaphore
            // Capture pixelBuffer explicitly to ensure ARC retains it for the async block
            let buffer = pixelBuffer

            ndiQueue.async { [weak self] in
                defer {
                    if backpressureEnabled {
                        semaphore.signal()
                    }
                    // ARC automatically releases buffer when closure completes
                    _ = buffer
                }
                guard let self = self else { return }
                self.sendFrameSync(pixelBuffer: buffer, sender: sender, frameTemplate: snapshot.frameTemplate, fps: snapshot.fps)
                self.statsLock.withLock { $0.sent += 1 }
            }
        } else {
            // Original synchronous behavior for rollback
            sendFrameSync(pixelBuffer: pixelBuffer, sender: sender, frameTemplate: snapshot.frameTemplate, fps: snapshot.fps)
            statsLock.withLock { $0.sent += 1 }
            if enableBackpressure {
                ndiSemaphore.signal()
            }
        }
    }

    /// PERF: Synchronous frame send with signposts and reused structs
    private func sendFrameSync(pixelBuffer: CVPixelBuffer, sender: NDIlib_send_instance_t, frameTemplate: NDIlib_video_frame_v2_t, fps: Int) {
        // PERF: Signpost begin
        if enableSignposts {
            os_signpost(.begin, log: perfLog, name: "NDI Send", signpostID: sendSignpostID)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Use pre-snapshotted frame template (no lock needed on hot path)
        var videoFrame = frameTemplate
        videoFrame.xres = Int32(width)
        videoFrame.yres = Int32(height)

        if !enableReducedAllocation {
            videoFrame.frame_rate_N = Int32(fps * 1000)
            videoFrame.frame_rate_D = 1000
        }

        // Set FourCC based on pixel format
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            videoFrame.FourCC = NDIlib_FourCC_video_type_NV12
            videoFrame.p_data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?
                .assumingMemoryBound(to: UInt8.self)
            videoFrame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        } else if pixelFormat == kCVPixelFormatType_32BGRA {
            videoFrame.FourCC = NDIlib_FourCC_video_type_BGRA
            videoFrame.p_data = CVPixelBufferGetBaseAddress(pixelBuffer)?
                .assumingMemoryBound(to: UInt8.self)
            videoFrame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))
        } else {
            if enableSignposts {
                os_signpost(.end, log: perfLog, name: "NDI Send", signpostID: sendSignpostID)
            }
            return
        }

        // Send the frame synchronously to NDI (safe: pixel buffer stays locked in defer above)
        NDIlib_send_send_video_v2(sender, &videoFrame)

        // PERF: Signpost end
        if enableSignposts {
            os_signpost(.end, log: perfLog, name: "NDI Send", signpostID: sendSignpostID)
        }

        // PERF: Update frame stats (zero-alloc or original path)
        updateFrameStats()
    }

    /// PERF: Zero-allocation frame stats using mach_absolute_time
    private func updateFrameStats() {
        let now = mach_absolute_time()

        let logCounter = stateLock.withLock { state -> Int? in
            state.frameStatsCounter += 1

            if state.frameStatsLastPrint == 0 {
                state.frameStatsLastPrint = now
                return nil
            }

            let timebase = NDIManager.machTimebase
            let elapsed = (now - state.frameStatsLastPrint) * UInt64(timebase.numer) / UInt64(timebase.denom)

            if elapsed >= 1_000_000_000 {
                let counter = state.frameStatsCounter
                state.frameStatsCounter = 0
                state.frameStatsLastPrint = now
                return counter
            }
            return nil
        }

        if let counter = logCounter {
            let connections = getConnectionCount()
            let stats = statsLock.withLock { $0 }
            print("📡 NDI: \(counter) fps, \(connections) conn, sent: \(stats.sent), dropped: \(stats.dropped)")
        }
    }

    // MARK: - Metadata

    func sendMetadata(xml: String) {
        let sender = stateLock.withLock { state -> NDIlib_send_instance_t? in
            guard state.isActive else { return nil }
            return state.ndiSender
        }
        guard let sender = sender else { return }

        var xmlCopy = xml
        xmlCopy.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { cchars in
                var metadata = NDIlib_metadata_frame_t()
                metadata.p_data = UnsafeMutablePointer(mutating: cchars.baseAddress)
                metadata.length = Int32(buffer.count)
                NDIlib_send_send_metadata(sender, &metadata)
            }
        }
    }

    func updateMetadata(whiteBalance: (mode: String, kelvin: Int?), iso: Int, shutter: Double) {
        let metadataXML = """
        <avocam>
          <alias>\(alias)</alias>
          <wb_mode>\(whiteBalance.mode)</wb_mode>
          <wb_kelvin>\(whiteBalance.kelvin ?? 0)</wb_kelvin>
          <iso>\(iso)</iso>
          <shutter>\(shutter)</shutter>
        </avocam>
        """

        sendMetadata(xml: metadataXML)
        print("📝 NDI metadata updated")
    }

    // MARK: - Status

    func getConnectionCount() -> Int {
        let sender = stateLock.withLock { $0.ndiSender }
        guard let sender = sender else { return 0 }
        return Int(NDIlib_send_get_no_connections(sender, 0))
    }

    func getTallyState() -> (program: Bool, preview: Bool) {
        let sender = stateLock.withLock { $0.ndiSender }
        guard let sender = sender else { return (false, false) }

        var tally = NDIlib_tally_t()
        NDIlib_send_get_tally(sender, &tally, 0)

        return (tally.on_program, tally.on_preview)
    }

    // MARK: - Telemetry

    /// Returns current streaming telemetry: (fps, sentFrames, droppedFrames)
    func getTelemetryStats() -> (fps: Double, sentFrames: Int64, droppedFrames: Int64) {
        let (active, fps) = stateLock.withLock { state -> (Bool, Double) in
            guard state.isActive else { return (false, 0.0) }
            return (true, Double(state.frameStatsCounter))
        }
        guard active else {
            return (0.0, 0, 0)
        }

        let stats = statsLock.withLock { $0 }
        return (fps, stats.sent, stats.dropped)
    }
}
