//
//  RTPPacketizer.swift
//  AvoCam
//
//  RFC 6184 H.264/RTP packetizer for Flash streaming
//

import Foundation
import CoreMedia
import CoreVideo

/// Errors that can occur during RTP packetization
enum RTPPacketizerError: Error {
    case invalidSampleBuffer
    case noDataBlockBuffer
    case failedToGetDataPointer
    case invalidNALUnit
}

/// RTP packetizer conforming to RFC 6184 for H.264 video
actor RTPPacketizer {
    // MARK: - Constants

    /// Maximum Transmission Unit (safe for most networks)
    private static let MTU: Int = 1400
    /// RTP header size (12 bytes)
    private static let RTPHeaderSize: Int = 12
    /// Maximum RTP payload size
    private static let MaxPayloadSize: Int = MTU - RTPHeaderSize // 1388 bytes
    /// FU-A header size (2 bytes: FU indicator + FU header)
    private static let FUAHeaderSize: Int = 2
    /// Maximum FU-A payload size
    private static let MaxFUAPayloadSize: Int = MaxPayloadSize - FUAHeaderSize // 1386 bytes

    // MARK: - RTP Packet Structure

    struct RTPPacket {
        let data: Data          // Full RTP packet with header
        let timestamp: UInt32   // RTP timestamp (90kHz)
        let sequenceNumber: UInt16
        let marker: Bool        // Marker bit (1 = last packet of access unit)
    }

    // MARK: - Properties

    /// RTP sequence number (16-bit, wraps around)
    private var sequenceNumber: UInt16
    /// Synchronization source identifier (random)
    private let ssrc: UInt32
    /// RTP payload type for H.264 (dynamic)
    private let payloadType: UInt8 = 96
    /// RTP version (always 2)
    private let version: UInt8 = 2

    // MARK: - Initialization

    init() {
        // Generate random SSRC
        self.ssrc = UInt32.random(in: 0...UInt32.max)
        // Start with random sequence number for security
        self.sequenceNumber = UInt16.random(in: 0...UInt16.max)

        Log.rtp.info("RTPPacketizer initialized (SSRC: 0x\(String(format: "%08X", ssrc)))")
    }

    // MARK: - Packetization

    /// Packetize a CMSampleBuffer containing H.264 encoded data
    /// - Parameter sampleBuffer: Encoded H.264 sample buffer from VideoToolbox
    /// - Returns: Array of RTP packets ready for transmission
    func packetize(sampleBuffer: CMSampleBuffer) throws -> [RTPPacket] {
        // Extract NAL units from sample buffer (AVCC format)
        let nalUnits = try extractNALUnits(from: sampleBuffer)

        guard !nalUnits.isEmpty else {
            throw RTPPacketizerError.invalidSampleBuffer
        }

        // Convert CMTime to RTP timestamp (90kHz clock)
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rtpTimestamp = cmTimeToRTPTimestamp(presentationTime)

        var packets: [RTPPacket] = []

        // Process each NAL unit
        for (index, nalUnit) in nalUnits.enumerated() {
            let isLastNAL = (index == nalUnits.count - 1)

            if nalUnit.count <= Self.MaxPayloadSize {
                // Single NAL unit packet
                let packet = createSingleNALPacket(
                    nalUnit: nalUnit,
                    timestamp: rtpTimestamp,
                    marker: isLastNAL
                )
                packets.append(packet)
            } else {
                // Fragmentation Unit A (FU-A) for large NAL units
                let fuaPackets = createFUAPackets(
                    nalUnit: nalUnit,
                    timestamp: rtpTimestamp,
                    marker: isLastNAL
                )
                packets.append(contentsOf: fuaPackets)
            }
        }

        return packets
    }

    // MARK: - NAL Unit Extraction

    /// Extract NAL units from AVCC format sample buffer, including SPS/PPS for keyframes
    /// - Parameter sampleBuffer: Sample buffer from VideoToolbox
    /// - Returns: Array of NAL units (without start codes)
    private func extractNALUnits(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        var nalUnits: [Data] = []

        // Check if this is a keyframe - if so, extract and prepend SPS/PPS
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           first[kCMSampleAttachmentKey_NotSync] as? Bool != true {
            // This is a sync frame (keyframe) - extract SPS/PPS from format description
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let parameterSets = extractParameterSets(from: formatDesc)
                nalUnits.append(contentsOf: parameterSets)
            }
        }

        // Extract NAL units from data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw RTPPacketizerError.noDataBlockBuffer
        }

        // Get data pointer
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            throw RTPPacketizerError.failedToGetDataPointer
        }

        var offset = 0

        // Parse AVCC format (4-byte length prefix + NAL unit)
        while offset < totalLength {
            // Read 4-byte length (big-endian) - use unaligned load to avoid crash
            guard offset + 4 <= totalLength else { break }

            // Read bytes manually to avoid alignment issues
            let byte0 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset)[0]))
            let byte1 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 1)[0]))
            let byte2 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 2)[0]))
            let byte3 = UInt32(UInt8(bitPattern: pointer.advanced(by: offset + 3)[0]))
            let nalLength = (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
            offset += 4

            // Extract NAL unit
            guard offset + Int(nalLength) <= totalLength else { break }

            let nalData = Data(bytes: pointer.advanced(by: offset), count: Int(nalLength))
            nalUnits.append(nalData)

            offset += Int(nalLength)
        }

        return nalUnits
    }

    /// Extract SPS and PPS from H.264 format description
    /// - Parameter formatDescription: CMFormatDescription from the sample buffer
    /// - Returns: Array of parameter set NAL units (SPS, PPS)
    private func extractParameterSets(from formatDescription: CMFormatDescription) -> [Data] {
        var parameterSets: [Data] = []

        // Get number of parameter sets
        var parameterSetCount: Int = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: nil
        )

        guard status == noErr else {
            Log.rtp.warning("Failed to get H.264 parameter set count: \(status)")
            return parameterSets
        }

        // Extract each parameter set (typically SPS at index 0, PPS at index 1)
        for i in 0..<parameterSetCount {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize: Int = 0

            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: i,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            if status == noErr, let pointer = parameterSetPointer, parameterSetSize > 0 {
                let data = Data(bytes: pointer, count: parameterSetSize)
                parameterSets.append(data)
            }
        }

        return parameterSets
    }

    // MARK: - Packet Creation

    /// Create a single NAL unit RTP packet
    /// - Parameters:
    ///   - nalUnit: NAL unit data
    ///   - timestamp: RTP timestamp
    ///   - marker: Marker bit value
    /// - Returns: RTP packet
    private func createSingleNALPacket(nalUnit: Data, timestamp: UInt32, marker: Bool) -> RTPPacket {
        let seqNum = getNextSequenceNumber()

        var packetData = Data()

        // RTP header (12 bytes)
        packetData.append(createRTPHeader(
            sequenceNumber: seqNum,
            timestamp: timestamp,
            marker: marker
        ))

        // NAL unit payload (unchanged)
        packetData.append(nalUnit)

        return RTPPacket(
            data: packetData,
            timestamp: timestamp,
            sequenceNumber: seqNum,
            marker: marker
        )
    }

    /// Create FU-A (Fragmentation Unit A) packets for large NAL units
    /// - Parameters:
    ///   - nalUnit: NAL unit to fragment
    ///   - timestamp: RTP timestamp
    ///   - marker: Marker bit for last packet
    /// - Returns: Array of fragmented RTP packets
    private func createFUAPackets(nalUnit: Data, timestamp: UInt32, marker: Bool) -> [RTPPacket] {
        var packets: [RTPPacket] = []

        // Extract NAL header (first byte)
        let nalHeader = nalUnit[0]
        let nalType = nalHeader & 0x1F
        let nalRefIdc = (nalHeader & 0x60) >> 5

        // FU indicator: nal_ref_idc (3 bits) + type=28 for FU-A (5 bits)
        let fuIndicator: UInt8 = (nalRefIdc << 5) | 28

        // Payload starts after NAL header
        // Convert to Data to reset indices to zero-based (dropFirst returns a Slice with offset indices)
        let payload = Data(nalUnit.dropFirst())
        var offset = 0
        let totalPayloadSize = payload.count

        while offset < totalPayloadSize {
            let isFirstPacket = (offset == 0)
            let remainingBytes = totalPayloadSize - offset
            let chunkSize = min(Self.MaxFUAPayloadSize, remainingBytes)
            let isLastPacket = (offset + chunkSize >= totalPayloadSize)

            // FU header: S (1 bit) | E (1 bit) | R (1 bit) | Type (5 bits)
            var fuHeader: UInt8 = nalType
            if isFirstPacket {
                fuHeader |= 0x80  // Set Start bit
            }
            if isLastPacket {
                fuHeader |= 0x40  // Set End bit
            }

            let seqNum = getNextSequenceNumber()
            var packetData = Data()

            // RTP header
            packetData.append(createRTPHeader(
                sequenceNumber: seqNum,
                timestamp: timestamp,
                marker: marker && isLastPacket
            ))

            // FU-A headers
            packetData.append(fuIndicator)
            packetData.append(fuHeader)

            // Payload fragment
            let chunk = payload[offset..<(offset + chunkSize)]
            packetData.append(contentsOf: chunk)

            packets.append(RTPPacket(
                data: packetData,
                timestamp: timestamp,
                sequenceNumber: seqNum,
                marker: marker && isLastPacket
            ))

            offset += chunkSize
        }

        return packets
    }

    /// Create RTP header (12 bytes)
    /// - Parameters:
    ///   - sequenceNumber: RTP sequence number
    ///   - timestamp: RTP timestamp (90kHz)
    ///   - marker: Marker bit
    /// - Returns: RTP header data
    private func createRTPHeader(sequenceNumber: UInt16, timestamp: UInt32, marker: Bool) -> Data {
        var header = Data(count: 12)

        // Byte 0: V=2 (2 bits) | P=0 (1 bit) | X=0 (1 bit) | CC=0 (4 bits)
        header[0] = (version << 6)

        // Byte 1: M (1 bit) | PT (7 bits)
        header[1] = marker ? (0x80 | payloadType) : payloadType

        // Bytes 2-3: Sequence number (big-endian)
        header[2] = UInt8((sequenceNumber >> 8) & 0xFF)
        header[3] = UInt8(sequenceNumber & 0xFF)

        // Bytes 4-7: Timestamp (big-endian)
        header[4] = UInt8((timestamp >> 24) & 0xFF)
        header[5] = UInt8((timestamp >> 16) & 0xFF)
        header[6] = UInt8((timestamp >> 8) & 0xFF)
        header[7] = UInt8(timestamp & 0xFF)

        // Bytes 8-11: SSRC (big-endian)
        header[8] = UInt8((ssrc >> 24) & 0xFF)
        header[9] = UInt8((ssrc >> 16) & 0xFF)
        header[10] = UInt8((ssrc >> 8) & 0xFF)
        header[11] = UInt8(ssrc & 0xFF)

        return header
    }

    // MARK: - Helper Methods

    /// Get next sequence number (wraps at 65535)
    /// - Returns: Next sequence number
    private func getNextSequenceNumber() -> UInt16 {
        let current = sequenceNumber
        sequenceNumber = sequenceNumber &+ 1  // Wrapping addition
        return current
    }

    /// Convert CMTime to RTP timestamp (90kHz clock)
    /// - Parameter time: CMTime presentation timestamp
    /// - Returns: RTP timestamp (wraps naturally at 32-bit)
    private func cmTimeToRTPTimestamp(_ time: CMTime) -> UInt32 {
        // RTP uses 90kHz clock for video
        // Handle invalid times
        guard time.isValid && !time.isIndefinite else {
            return 0
        }

        let seconds = CMTimeGetSeconds(time)

        // Guard against negative, infinity or NaN values
        guard seconds.isFinite && seconds >= 0 else {
            return 0
        }

        // Convert to 90kHz ticks
        // UInt64 can hold the full range, then truncate to UInt32 (natural wrap)
        let ticks = UInt64(seconds * 90000.0)
        return UInt32(truncatingIfNeeded: ticks)
    }
}
