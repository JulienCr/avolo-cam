//
//  AVOCamError.swift
//  AvoCam
//
//  Unified error type for the AVOLO-CAM iOS application
//

import Foundation

/// Unified error type for all AVOLO-CAM operations
enum AVOCamError: LocalizedError {
    // MARK: - Streaming Errors
    case alreadyStreaming
    case notStreaming

    // MARK: - Capture Errors
    case deviceNotAvailable
    case cannotAddInput
    case cannotAddOutput
    case sessionNotConfigured
    case formatNotSupported
    case invalidResolution
    case invalidWhiteBalanceGains
    case whiteBalanceNotSupported

    // MARK: - Network Errors
    case serverStartFailed
    case invalidRequest
    case networkError(String)

    // MARK: - Configuration Errors
    case invalidConfiguration

    // MARK: - Generic Error
    case genericError(String)

    // MARK: - LocalizedError Conformance

    var errorDescription: String? {
        switch self {
        // Streaming
        case .alreadyStreaming:
            return "Stream is already active"
        case .notStreaming:
            return "Stream is not active"

        // Capture
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

        // Network
        case .serverStartFailed:
            return "Failed to start server"
        case .invalidRequest:
            return "Invalid request"
        case .networkError(let message):
            return "Network error: \(message)"

        // Configuration
        case .invalidConfiguration:
            return "Invalid configuration provided"

        // Generic
        case .genericError(let message):
            return message
        }
    }

    // MARK: - Error Code Property

    /// Returns a string code for the error suitable for API responses
    var errorCode: String {
        switch self {
        // Streaming
        case .alreadyStreaming:
            return "ALREADY_STREAMING"
        case .notStreaming:
            return "NOT_STREAMING"

        // Capture
        case .deviceNotAvailable:
            return "DEVICE_NOT_AVAILABLE"
        case .cannotAddInput:
            return "CANNOT_ADD_INPUT"
        case .cannotAddOutput:
            return "CANNOT_ADD_OUTPUT"
        case .sessionNotConfigured:
            return "SESSION_NOT_CONFIGURED"
        case .formatNotSupported:
            return "FORMAT_NOT_SUPPORTED"
        case .invalidResolution:
            return "INVALID_RESOLUTION"
        case .invalidWhiteBalanceGains:
            return "INVALID_WHITE_BALANCE_GAINS"
        case .whiteBalanceNotSupported:
            return "WHITE_BALANCE_NOT_SUPPORTED"

        // Network
        case .serverStartFailed:
            return "SERVER_START_FAILED"
        case .invalidRequest:
            return "INVALID_REQUEST"
        case .networkError:
            return "NETWORK_ERROR"

        // Configuration
        case .invalidConfiguration:
            return "INVALID_CONFIGURATION"

        // Generic
        case .genericError:
            return "GENERIC_ERROR"
        }
    }
}
