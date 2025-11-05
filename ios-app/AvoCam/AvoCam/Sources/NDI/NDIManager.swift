//
//  NDIManager.swift
//  AvoCam
//
//  Manages NDI video transmission via NDI SDK
//

import Foundation
import CoreMedia
import CoreVideo

class NDIManager {
    // MARK: - Properties

    private let alias: String
    private var ndiSender: NDIlib_send_instance_t?
    private var isActive: Bool = false
    private var currentFPS: Int = 30

    // Frame rate logging
    private var frameCount: Int = 0
    private var lastLogTime: Date = Date()

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

    func start(width: Int = 1920, height: Int = 1080, fps: Int = 30) throws {
        guard !isActive else {
            print("⚠️ NDI sender already active")
            return
        }

        currentFPS = fps

        // Create NDI sender
        // Note: alias already has AVOLO-CAM- prefix from AppCoordinator
        let senderName = alias

        var sendSettings = NDIlib_send_create_t()
        senderName.withCString { namePtr in
            sendSettings.p_ndi_name = namePtr
            sendSettings.p_groups = nil
            sendSettings.clock_video = true
            sendSettings.clock_audio = false

            ndiSender = NDIlib_send_create(&sendSettings)
        }

        guard ndiSender != nil else {
            throw NSError(
                domain: "NDIManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create NDI sender"]
            )
        }

        isActive = true
        frameCount = 0
        lastLogTime = Date()

        print("✅ NDI sender started: \(senderName) (\(width)x\(height)@\(fps)fps)")
    }

    func stop() {
        guard isActive else { return }

        if let sender = ndiSender {
            NDIlib_send_destroy(sender)
        }

        isActive = false
        ndiSender = nil
        print("⏹ NDI sender stopped")
    }

    // MARK: - Send Video Frame

    func send(pixelBuffer: CVPixelBuffer) {
        guard isActive, let sender = ndiSender else { return }

        // Lock the pixel buffer for reading
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Create NDI video frame
        var videoFrame = NDIlib_video_frame_v2_t()
        videoFrame.xres = Int32(width)
        videoFrame.yres = Int32(height)
        videoFrame.frame_rate_N = Int32(currentFPS * 1000)
        videoFrame.frame_rate_D = 1000

        // Set FourCC based on pixel format
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // NV12 format
            videoFrame.FourCC = NDIlib_FourCC_video_type_NV12
            videoFrame.p_data = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?
                .assumingMemoryBound(to: UInt8.self)
            videoFrame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        } else if pixelFormat == kCVPixelFormatType_32BGRA {
            // BGRA format
            videoFrame.FourCC = NDIlib_FourCC_video_type_BGRA
            videoFrame.p_data = CVPixelBufferGetBaseAddress(pixelBuffer)?
                .assumingMemoryBound(to: UInt8.self)
            videoFrame.line_stride_in_bytes = Int32(CVPixelBufferGetBytesPerRow(pixelBuffer))
        } else {
            print("⚠️ Unsupported pixel format: \(pixelFormat)")
            return
        }

        // Send the frame asynchronously
        NDIlib_send_send_video_async_v2(sender, &videoFrame)

        // Frame rate logging (every 1 second)
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 1.0 {
            let connections = getConnectionCount()
            print("📡 NDI sending at \(frameCount) fps (connections: \(connections))")
            frameCount = 0
            lastLogTime = now
        }
    }

    // MARK: - Metadata

    func sendMetadata(xml: String) {
        guard isActive, let sender = ndiSender else { return }

        xml.withCString { xmlPtr in
            NDIlib_send_send_metadata(sender, xmlPtr)
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
        guard let sender = ndiSender else { return 0 }
        return Int(NDIlib_send_get_no_connections(sender, 0))
    }

    func getTallyState() -> (program: Bool, preview: Bool) {
        guard let sender = ndiSender else { return (false, false) }

        var tally = NDIlib_tally_t()
        NDIlib_send_get_tally(sender, &tally, 0)

        return (tally.on_program, tally.on_preview)
    }
}
