//
//  TSMuxer.swift
//  AvoCam
//
//  MPEG-TS Muxer for wrapping H.264 NAL units in Transport Stream format
//  Required for SRT streaming to VLC/OBS
//

import Foundation
import CoreMedia

/// MPEG-TS Muxer for wrapping H.264 in Transport Stream format
/// Converts raw H.264 NAL units to MPEG-TS packets (188 bytes each)
/// This class is nonisolated to allow efficient use from the SRTManager actor
nonisolated final class TSMuxer: @unchecked Sendable {
    // MARK: - Constants

    /// MPEG-TS packet size (fixed at 188 bytes)
    private let tsPacketSize = 188

    /// Sync byte that starts every TS packet
    private let syncByte: UInt8 = 0x47

    // PIDs (Packet Identifiers)
    private let patPid: UInt16 = 0x0000      // Program Association Table
    private let pmtPid: UInt16 = 0x1000      // Program Map Table
    private let videoPid: UInt16 = 0x0100    // Video elementary stream

    // Stream types
    private let streamTypeH264: UInt8 = 0x1B // AVC/H.264

    // MARK: - State

    /// Lock for thread-safe access to mutable state
    private let lock = NSLock()

    /// Continuity counters (0-15, wrap around for each PID)
    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var videoCC: UInt8 = 0

    /// PCR base time (90kHz clock)
    private var pcrBase: Int64 = 0
    private var startTime: CMTime?

    /// Frame counter for periodic PAT/PMT
    private var frameCounter: Int = 0

    // MARK: - Public API

    /// Mux H.264 sample buffer into MPEG-TS packets
    /// - Parameter sampleBuffer: Encoded H.264 CMSampleBuffer from VideoToolbox
    /// - Returns: Data containing 188-byte TS packets ready for SRT transmission
    func mux(sampleBuffer: CMSampleBuffer) -> Data {
        lock.lock()
        defer { lock.unlock() }

        var output = Data()

        // Initialize start time on first frame
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if startTime == nil {
            startTime = pts
        }

        // Check if this is a keyframe
        let isKeyframe = isKeyFrame(sampleBuffer)

        // Send PAT and PMT frequently (every 2 frames) or before keyframes
        // More frequent PSI = faster decoder sync for clients joining mid-stream (~100-150ms improvement)
        let shouldSendPSI = isKeyframe || (frameCounter % 2 == 0)
        if shouldSendPSI {
            output.append(createPAT())
            output.append(createPMT())
        }
        frameCounter += 1

        // Extract H.264 data
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return output
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let pointer = dataPointer, length > 0 else {
            return output
        }

        let nalData = Data(bytes: pointer, count: length)

        // Convert AVCC format to Annex-B format (replace length prefix with start codes)
        let annexBData = convertToAnnexB(nalData, isKeyframe: isKeyframe, sampleBuffer: sampleBuffer)

        // Get timestamps
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let effectiveDts = dts.isValid ? dts : pts

        // Create PES packet wrapping the H.264 data
        let pesPacket = createPES(data: annexBData, pts: pts, dts: effectiveDts)

        // Split PES into 188-byte TS packets
        output.append(packetizePES(pesPacket, isKeyframe: isKeyframe, pts: pts))

        return output
    }

    /// Reset muxer state (call when starting a new stream)
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        patCC = 0
        pmtCC = 0
        videoCC = 0
        pcrBase = 0
        startTime = nil
        frameCounter = 0
    }

    // MARK: - Private: PAT (Program Association Table)

    /// Create a PAT packet
    /// PAT tells the decoder which PID contains the PMT
    private func createPAT() -> Data {
        var packet = Data(count: tsPacketSize)

        // TS Header (4 bytes)
        packet[0] = syncByte
        packet[1] = 0x40  // payload_unit_start_indicator = 1, PID high bits = 0
        packet[2] = 0x00  // PID low bits = 0x00 (PAT)
        packet[3] = 0x10 | (patCC & 0x0F)  // no adaptation field, payload only
        patCC = (patCC + 1) & 0x0F

        // Pointer field (required when payload_unit_start_indicator = 1)
        packet[4] = 0x00

        // PAT Section
        var offset = 5

        packet[offset] = 0x00  // table_id = 0x00 (PAT)
        offset += 1

        // section_syntax_indicator (1) + '0' + reserved (2) + section_length (12)
        // Section length = 13 bytes (from here to CRC, including CRC)
        packet[offset] = 0xB0  // 1011 0000
        offset += 1
        packet[offset] = 0x0D  // section_length = 13
        offset += 1

        // transport_stream_id
        packet[offset] = 0x00
        offset += 1
        packet[offset] = 0x01
        offset += 1

        // reserved (2) + version_number (5) + current_next_indicator (1)
        packet[offset] = 0xC1  // 1100 0001
        offset += 1

        // section_number
        packet[offset] = 0x00
        offset += 1

        // last_section_number
        packet[offset] = 0x00
        offset += 1

        // Program entry: program_number (16) + reserved (3) + program_map_PID (13)
        // program_number = 1
        packet[offset] = 0x00
        offset += 1
        packet[offset] = 0x01
        offset += 1

        // PMT PID = 0x1000
        packet[offset] = 0xE0 | UInt8((pmtPid >> 8) & 0x1F)  // reserved (3) + PID high bits
        offset += 1
        packet[offset] = UInt8(pmtPid & 0xFF)  // PID low bits
        offset += 1

        // CRC32 (calculated over section data starting at table_id)
        let crc = calculateCRC32(data: packet, start: 5, length: offset - 5)
        packet[offset] = UInt8((crc >> 24) & 0xFF)
        offset += 1
        packet[offset] = UInt8((crc >> 16) & 0xFF)
        offset += 1
        packet[offset] = UInt8((crc >> 8) & 0xFF)
        offset += 1
        packet[offset] = UInt8(crc & 0xFF)
        offset += 1

        // Fill remainder with 0xFF (stuffing bytes)
        for i in offset..<tsPacketSize {
            packet[i] = 0xFF
        }

        return packet
    }

    // MARK: - Private: PMT (Program Map Table)

    /// Create a PMT packet
    /// PMT describes the streams in the program (one H.264 video stream)
    private func createPMT() -> Data {
        var packet = Data(count: tsPacketSize)

        // TS Header (4 bytes)
        packet[0] = syncByte
        packet[1] = 0x40 | UInt8((pmtPid >> 8) & 0x1F)  // payload_unit_start = 1, PID high
        packet[2] = UInt8(pmtPid & 0xFF)  // PID low
        packet[3] = 0x10 | (pmtCC & 0x0F)  // no adaptation field, payload only
        pmtCC = (pmtCC + 1) & 0x0F

        // Pointer field
        packet[4] = 0x00

        // PMT Section
        var offset = 5

        packet[offset] = 0x02  // table_id = 0x02 (PMT)
        offset += 1

        // section_syntax_indicator (1) + '0' + reserved (2) + section_length (12)
        // Section length = 18 bytes
        packet[offset] = 0xB0  // 1011 0000
        offset += 1
        packet[offset] = 0x12  // section_length = 18
        offset += 1

        // program_number
        packet[offset] = 0x00
        offset += 1
        packet[offset] = 0x01
        offset += 1

        // reserved (2) + version_number (5) + current_next_indicator (1)
        packet[offset] = 0xC1  // 1100 0001
        offset += 1

        // section_number
        packet[offset] = 0x00
        offset += 1

        // last_section_number
        packet[offset] = 0x00
        offset += 1

        // reserved (3) + PCR_PID (13) - use video PID for PCR
        packet[offset] = 0xE0 | UInt8((videoPid >> 8) & 0x1F)
        offset += 1
        packet[offset] = UInt8(videoPid & 0xFF)
        offset += 1

        // reserved (4) + program_info_length (12) = 0
        packet[offset] = 0xF0
        offset += 1
        packet[offset] = 0x00
        offset += 1

        // Stream entry for video
        // stream_type (8)
        packet[offset] = streamTypeH264  // 0x1B = AVC/H.264
        offset += 1

        // reserved (3) + elementary_PID (13)
        packet[offset] = 0xE0 | UInt8((videoPid >> 8) & 0x1F)
        offset += 1
        packet[offset] = UInt8(videoPid & 0xFF)
        offset += 1

        // reserved (4) + ES_info_length (12) = 0
        packet[offset] = 0xF0
        offset += 1
        packet[offset] = 0x00
        offset += 1

        // CRC32
        let crc = calculateCRC32(data: packet, start: 5, length: offset - 5)
        packet[offset] = UInt8((crc >> 24) & 0xFF)
        offset += 1
        packet[offset] = UInt8((crc >> 16) & 0xFF)
        offset += 1
        packet[offset] = UInt8((crc >> 8) & 0xFF)
        offset += 1
        packet[offset] = UInt8(crc & 0xFF)
        offset += 1

        // Fill remainder with 0xFF
        for i in offset..<tsPacketSize {
            packet[i] = 0xFF
        }

        return packet
    }

    // MARK: - Private: PES (Packetized Elementary Stream)

    /// Create a PES packet from H.264 data
    private func createPES(data: Data, pts: CMTime, dts: CMTime) -> Data {
        var pes = Data()

        // PES start code prefix (3 bytes)
        pes.append(contentsOf: [0x00, 0x00, 0x01])

        // Stream ID (1 byte) - 0xE0 = video stream 0
        pes.append(0xE0)

        // Calculate PES header length
        let hasDts = dts != pts
        let ptsOnly = !hasDts
        let headerDataLength = ptsOnly ? 5 : 10  // PTS only = 5 bytes, PTS+DTS = 10 bytes
        let pesHeaderLength = 3 + headerDataLength  // flags (2) + header_data_length (1) + pts/dts

        // PES packet length (2 bytes)
        // 0 = unbounded (for video), or actual length if it fits in 16 bits
        let totalLength = pesHeaderLength + data.count
        if totalLength <= 65535 {
            pes.append(UInt8((totalLength >> 8) & 0xFF))
            pes.append(UInt8(totalLength & 0xFF))
        } else {
            // Unbounded (video can exceed 64KB)
            pes.append(0x00)
            pes.append(0x00)
        }

        // PES header flags (2 bytes)
        // Byte 1: '10' + PES_scrambling_control (00) + PES_priority (0) +
        //         data_alignment_indicator (1) + copyright (0) + original_or_copy (0)
        pes.append(0x84)  // 1000 0100 - data alignment indicator set

        // Byte 2: PTS_DTS_flags (2) + other flags
        if ptsOnly {
            pes.append(0x80)  // PTS only (10)
        } else {
            pes.append(0xC0)  // PTS and DTS (11)
        }

        // PES header data length (1 byte)
        pes.append(UInt8(headerDataLength))

        // PTS (5 bytes) - 90kHz clock
        let pts90k = convertTo90kHz(pts)
        pes.append(contentsOf: encodePTS(pts90k, marker: ptsOnly ? 0x21 : 0x31))

        // DTS (5 bytes) if different from PTS
        if !ptsOnly {
            let dts90k = convertTo90kHz(dts)
            pes.append(contentsOf: encodePTS(dts90k, marker: 0x11))
        }

        // Append H.264 data
        pes.append(data)

        return pes
    }

    /// Convert CMTime to 90kHz PTS/DTS value
    private func convertTo90kHz(_ time: CMTime) -> Int64 {
        guard let start = startTime else { return 0 }
        let elapsed = CMTimeSubtract(time, start)
        let seconds = CMTimeGetSeconds(elapsed)
        return Int64(seconds * 90000.0)
    }

    /// Encode PTS/DTS value into 5-byte format per MPEG-TS spec
    private func encodePTS(_ value: Int64, marker: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 5)

        // Format: 4 bits marker, 3 bits [32:30], 1 bit marker,
        //         15 bits [29:15], 1 bit marker,
        //         15 bits [14:0], 1 bit marker
        bytes[0] = marker | UInt8((value >> 29) & 0x0E)
        bytes[1] = UInt8((value >> 22) & 0xFF)
        bytes[2] = UInt8((value >> 14) & 0xFE) | 0x01
        bytes[3] = UInt8((value >> 7) & 0xFF)
        bytes[4] = UInt8((value << 1) & 0xFE) | 0x01

        return bytes
    }

    // MARK: - Private: TS Packetization

    /// Split PES data into 188-byte TS packets
    private func packetizePES(_ pesData: Data, isKeyframe: Bool, pts: CMTime) -> Data {
        var output = Data()
        var pesOffset = 0
        var isFirstPacket = true

        while pesOffset < pesData.count {
            var packet = Data(count: tsPacketSize)

            // TS Header (4 bytes)
            packet[0] = syncByte

            // PID
            let payloadUnitStart = isFirstPacket
            if payloadUnitStart {
                packet[1] = 0x40 | UInt8((videoPid >> 8) & 0x1F)
            } else {
                packet[1] = UInt8((videoPid >> 8) & 0x1F)
            }
            packet[2] = UInt8(videoPid & 0xFF)

            // Calculate how much PES data remains
            let remainingPes = pesData.count - pesOffset
            let maxPayloadWithoutAF = 184  // 188 - 4 (header)

            // Determine if we need adaptation field
            // Include PCR on keyframes and every 2 frames for better timing sync (~50-75ms improvement)
            let needPCR = isFirstPacket && (isKeyframe || frameCounter % 2 == 0)
            let needStuffing = remainingPes < maxPayloadWithoutAF
            let needAdaptationField = needPCR || needStuffing

            var payloadStart = 4
            var payloadSize = 0

            if needAdaptationField {
                // adaptation_field_control = 11 (both AF and payload)
                packet[3] = 0x30 | (videoCC & 0x0F)

                // Calculate adaptation field size
                var afContentSize = 0  // Size of content after adaptation_field_length byte

                if needPCR {
                    afContentSize = 1 + 6  // flags (1) + PCR (6)
                } else {
                    afContentSize = 1  // at least flags byte
                }

                // Calculate payload space: 184 - 1 (af_length byte) - afContentSize
                var availablePayload = maxPayloadWithoutAF - 1 - afContentSize

                // If we have less data than available space, add stuffing
                if remainingPes < availablePayload {
                    let stuffingNeeded = availablePayload - remainingPes
                    afContentSize += stuffingNeeded
                    availablePayload = remainingPes
                }

                payloadSize = min(remainingPes, availablePayload)

                // Write adaptation_field_length
                packet[4] = UInt8(afContentSize)
                payloadStart = 5

                // Write flags
                var flags: UInt8 = 0
                if isFirstPacket && isKeyframe {
                    flags |= 0x40  // random_access_indicator
                }
                if needPCR {
                    flags |= 0x10  // PCR_flag
                }
                packet[5] = flags
                payloadStart = 6

                // Write PCR if needed (6 bytes)
                if needPCR {
                    let pcr = convertTo90kHz(pts)
                    // PCR = base (33 bits) * 300 + extension (9 bits)
                    // We simplify: PCR base = PTS, extension = 0
                    packet[6] = UInt8((pcr >> 25) & 0xFF)
                    packet[7] = UInt8((pcr >> 17) & 0xFF)
                    packet[8] = UInt8((pcr >> 9) & 0xFF)
                    packet[9] = UInt8((pcr >> 1) & 0xFF)
                    // Last bit of PCR base + reserved (6 bits) + PCR ext high (1 bit)
                    packet[10] = UInt8((pcr & 0x01) << 7) | 0x7E
                    packet[11] = 0x00  // PCR extension low 8 bits
                    payloadStart = 12
                }

                // Fill remaining adaptation field with stuffing (0xFF)
                let afEnd = 5 + afContentSize  // 4 (header) + 1 (af_length) + afContentSize
                for i in payloadStart..<afEnd {
                    packet[i] = 0xFF
                }
                payloadStart = afEnd

            } else {
                // No adaptation field - payload only
                packet[3] = 0x10 | (videoCC & 0x0F)
                payloadSize = maxPayloadWithoutAF
            }

            videoCC = (videoCC + 1) & 0x0F
            isFirstPacket = false

            // Copy payload
            if payloadSize > 0 && pesOffset + payloadSize <= pesData.count {
                let payloadData = pesData.subdata(in: pesOffset..<(pesOffset + payloadSize))
                packet.replaceSubrange(payloadStart..<(payloadStart + payloadSize), with: payloadData)
                pesOffset += payloadSize
            }

            // Verify packet is complete (should always be 188 bytes with payload + stuffing)
            assert(payloadStart + payloadSize <= tsPacketSize, "TS packet overflow")

            output.append(packet)
        }

        return output
    }

    // MARK: - Private: H.264 Format Conversion

    /// Check if sample buffer contains a keyframe (IDR)
    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let firstAttachment = attachments.first else {
            return false
        }
        let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    /// Convert AVCC format (length-prefixed) to Annex-B format (start code prefixed)
    /// VideoToolbox outputs AVCC, but MPEG-TS expects Annex-B
    private func convertToAnnexB(_ avccData: Data, isKeyframe: Bool, sampleBuffer: CMSampleBuffer) -> Data {
        var annexBData = Data()

        // For keyframes, prepend SPS/PPS from format description
        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get SPS
                var spsSize: Int = 0
                var spsCount: Int = 0
                var spsPointer: UnsafePointer<UInt8>?
                let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer,
                    parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount,
                    nalUnitHeaderLengthOut: nil
                )

                if spsStatus == noErr, let sps = spsPointer {
                    annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    annexBData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }

                // Get PPS
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPointer,
                    parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )

                if ppsStatus == noErr, let pps = ppsPointer {
                    annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // Start code
                    annexBData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                }
            }
        }

        // Convert NAL units from AVCC (4-byte length prefix) to Annex-B (start codes)
        var offset = 0
        while offset + 4 <= avccData.count {
            // Read 4-byte length prefix (big-endian)
            let nalLength = Int(avccData[offset]) << 24 |
                           Int(avccData[offset + 1]) << 16 |
                           Int(avccData[offset + 2]) << 8 |
                           Int(avccData[offset + 3])

            offset += 4

            guard nalLength > 0, offset + nalLength <= avccData.count else {
                break
            }

            // Append start code
            annexBData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])

            // Append NAL unit data
            annexBData.append(avccData.subdata(in: offset..<(offset + nalLength)))

            offset += nalLength
        }

        return annexBData
    }

    // MARK: - Private: CRC32

    /// CRC32 lookup table for MPEG-2
    private static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i) << 24
            for _ in 0..<8 {
                if (crc & 0x80000000) != 0 {
                    crc = (crc << 1) ^ 0x04C11DB7
                } else {
                    crc = crc << 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Calculate CRC32 for MPEG-2 sections
    private func calculateCRC32(data: Data, start: Int, length: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for i in start..<(start + length) {
            let index = Int((crc >> 24) ^ UInt32(data[i])) & 0xFF
            crc = (crc << 8) ^ TSMuxer.crc32Table[index]
        }
        return crc
    }
}
