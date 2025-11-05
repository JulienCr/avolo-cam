//
//  NDIManager.swift
//  AvoCam
//
//  Manages NDI|HX video transmission
//
//  ⚠️ REQUIRES: NDI SDK integration
//  Download NDI SDK for iOS from: https://ndi.tv/sdk/
//  Add the framework to the project and update the bridging header
//

import Foundation
import CoreMedia

class NDIManager {
    // MARK: - Properties

    private let alias: String
    private var ndiSender: Any? // Will be NDISender from NDI SDK
    private var isActive: Bool = false

    // MARK: - Initialization

    init(alias: String) {
        self.alias = alias
        print("📡 NDI Manager initialized with alias: \(alias)")
    }

    // MARK: - NDI Control

    func start() throws {
        guard !isActive else { return }

        // TODO: Initialize NDI SDK
        // 1. Create NDI sender with name: "AVOLO-CAM-<alias>"
        // 2. Set up NDI|HX compression settings
        // 3. Configure metadata (alias, WB, ISO, shutter)
        //
        // Example pseudo-code:
        // let senderName = "AVOLO-CAM-\(alias)"
        // ndiSender = NDIlib_send_create(&sendSettings)
        // NDIlib_send_set_metadata(ndiSender, metadataXML)

        isActive = true
        print("✅ NDI sender started: AVOLO-CAM-\(alias)")
    }

    func stop() {
        guard isActive else { return }

        // TODO: Stop NDI sender
        // NDIlib_send_destroy(ndiSender)

        isActive = false
        ndiSender = nil
        print("⏹ NDI sender stopped")
    }

    // MARK: - Send Data

    func send(data: Data) {
        guard isActive else { return }

        // TODO: Send H.264 compressed frame via NDI|HX
        // Convert Data to NDI compressed video frame format
        //
        // Example pseudo-code:
        // var videoFrame = NDIlib_compressed_video_frame_v5_t()
        // videoFrame.data = data.withUnsafeBytes { $0.baseAddress }
        // videoFrame.data_size_in_bytes = Int32(data.count)
        // videoFrame.fourCC = NDIlib_compressed_FourCC_type_H264
        // NDIlib_send_send_video_compressed(ndiSender, &videoFrame)

        // For now, just log (remove in production)
        // print("📡 NDI send: \(data.count) bytes")
    }

    // MARK: - Metadata

    func updateMetadata(whiteBalance: (mode: String, kelvin: Int?), iso: Int, shutter: Double) {
        // TODO: Update NDI metadata
        // Create XML metadata string with camera parameters
        //
        // Example:
        // let metadataXML = """
        // <avocam>
        //   <alias>\(alias)</alias>
        //   <wb_mode>\(whiteBalance.mode)</wb_mode>
        //   <wb_kelvin>\(whiteBalance.kelvin ?? 0)</wb_kelvin>
        //   <iso>\(iso)</iso>
        //   <shutter>\(shutter)</shutter>
        // </avocam>
        // """
        // NDIlib_send_set_metadata(ndiSender, metadataXML)

        print("📝 NDI metadata updated")
    }

    // MARK: - Status

    func getConnectionCount() -> Int {
        // TODO: Get number of receivers connected
        // return NDIlib_send_get_no_connections(ndiSender, 0)
        return 0
    }
}

// MARK: - Integration Notes

/*
 NDI SDK Integration Steps:

 1. Download NDI SDK for iOS from https://ndi.tv/sdk/

 2. Add the NDI framework to your Xcode project:
    - Drag NDI iOS framework into Frameworks folder
    - Add to "Link Binary With Libraries" in Build Phases
    - Add to "Embed Frameworks" if needed

 3. Create Objective-C bridging header if needed:
    - File -> New -> File -> Header File
    - Name it "AvoCam-Bridging-Header.h"
    - Add: #import <NDI_iOS/NDI_iOS.h>
    - Set bridging header path in Build Settings

 4. Replace the TODO sections in this file with actual NDI SDK calls:
    - NDIlib_send_create() - Create sender
    - NDIlib_send_send_video_compressed() - Send H.264 frames
    - NDIlib_send_set_metadata() - Set metadata
    - NDIlib_send_get_no_connections() - Get receiver count
    - NDIlib_send_destroy() - Destroy sender

 5. Configure NDI|HX compression settings:
    - Use compressed video format (H.264)
    - Set FourCC to NDIlib_compressed_FourCC_type_H264
    - Ensure Rec.709 color space is maintained

 6. Test with OBS NDI Source plugin:
    - Verify stream appears as "AVOLO-CAM-<alias>"
    - Check color accuracy (should be Rec.709 Full)
    - Measure latency (target ≤150ms)
 */
