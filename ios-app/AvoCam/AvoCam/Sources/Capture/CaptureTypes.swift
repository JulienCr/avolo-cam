//
//  CaptureTypes.swift
//  AvoCam
//
//  Internal types for capture system
//

import AVFoundation

// MARK: - Errors

enum CaptureError: LocalizedError {
    case deviceNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case sessionNotConfigured
    case formatNotSupported
    case invalidResolution
    case invalidWhiteBalanceGains
    case whiteBalanceNotSupported

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Camera device not available"
        case .cannotAddInput:
            return "Cannot add capture input"
        case .cannotAddOutput:
            return "Cannot add capture output"
        case .sessionNotConfigured:
            return "Capture session not configured"
        case .formatNotSupported:
            return "Requested format not supported"
        case .invalidResolution:
            return "Invalid resolution format"
        case .invalidWhiteBalanceGains:
            return "White balance gains out of valid range"
        case .whiteBalanceNotSupported:
            return "White balance mode not supported"
        }
    }
}

// MARK: - Lens Constants

enum Lens {
    static let wide = "wide"
    static let ultraWide = "ultra_wide"
    static let telephoto = "telephoto"
}

// MARK: - Camera Position

enum CameraPosition: String {
    case front
    case back

    var asCapturePosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

// MARK: - Resolution

struct Resolution {
    let width: Int32
    let height: Int32

    var description: String {
        "\(width)x\(height)"
    }

    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    init(string: String) throws {
        let components = string.split(separator: "x").compactMap { Int32($0) }
        guard components.count == 2 else {
            throw CaptureError.invalidResolution
        }
        self.width = components[0]
        self.height = components[1]
    }
}
