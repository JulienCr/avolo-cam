//
//  NetworkError.swift
//  AvoCam
//
//  Unified network error types with HTTP status mapping
//

import Foundation

// MARK: - Network Error

enum NetworkError: Error, LocalizedError {
    // Server lifecycle
    case serverStartFailed
    case serverStopFailed

    // Request errors
    case invalidRequest
    case missingBody
    case decodingFailed(String)
    case encodingFailed(String)

    // Authentication & authorization
    case unauthorized
    case forbidden

    // Resource errors
    case notFound(String)
    case methodNotAllowed

    // Rate limiting
    case rateLimited(String)

    // Handler errors
    case handlerNotAvailable
    case handlerFailed(String)

    // Stream errors
    case streamStartFailed(String)
    case streamStopFailed(String)

    // Camera errors
    case cameraUpdateFailed(String)
    case measureFailed(String)

    // Settings errors
    case invalidAlias(String)
    case aliasUpdateFailed(String)
    case torchUpdateFailed(String)
    case videoSettingsUpdateFailed(String)

    // Generic errors
    case internalError(String)
    case notImplemented(String)

    // MARK: - HTTP Status Mapping

    /// Maps error to appropriate HTTP status code
    var httpStatus: HTTPStatus {
        switch self {
        case .serverStartFailed, .serverStopFailed:
            return .internalServerError
        case .invalidRequest, .missingBody, .decodingFailed, .invalidAlias:
            return .badRequest
        case .unauthorized:
            return .unauthorized
        case .forbidden:
            return .unauthorized
        case .notFound:
            return .notFound
        case .methodNotAllowed:
            return .notFound
        case .rateLimited:
            return .tooManyRequests
        case .handlerNotAvailable, .handlerFailed, .streamStartFailed, .streamStopFailed,
             .cameraUpdateFailed, .measureFailed, .aliasUpdateFailed, .torchUpdateFailed,
             .videoSettingsUpdateFailed, .encodingFailed, .internalError:
            return .internalServerError
        case .notImplemented:
            return .notImplemented
        }
    }

    // MARK: - Error Code

    /// Stable error code for API responses
    var code: String {
        switch self {
        case .serverStartFailed:
            return "SERVER_START_FAILED"
        case .serverStopFailed:
            return "SERVER_STOP_FAILED"
        case .invalidRequest:
            return "INVALID_REQUEST"
        case .missingBody:
            return "MISSING_BODY"
        case .decodingFailed:
            return "DECODING_FAILED"
        case .encodingFailed:
            return "ENCODING_FAILED"
        case .unauthorized:
            return "UNAUTHORIZED"
        case .forbidden:
            return "FORBIDDEN"
        case .notFound:
            return "NOT_FOUND"
        case .methodNotAllowed:
            return "METHOD_NOT_ALLOWED"
        case .rateLimited:
            return "RATE_LIMITED"
        case .handlerNotAvailable:
            return "INTERNAL_ERROR"
        case .handlerFailed:
            return "HANDLER_FAILED"
        case .streamStartFailed:
            return "STREAM_START_FAILED"
        case .streamStopFailed:
            return "STREAM_STOP_FAILED"
        case .cameraUpdateFailed:
            return "CAMERA_UPDATE_FAILED"
        case .measureFailed:
            return "MEASURE_FAILED"
        case .invalidAlias:
            return "INVALID_ALIAS"
        case .aliasUpdateFailed:
            return "ALIAS_UPDATE_FAILED"
        case .torchUpdateFailed:
            return "TORCH_UPDATE_FAILED"
        case .videoSettingsUpdateFailed:
            return "VIDEO_SETTINGS_UPDATE_FAILED"
        case .internalError:
            return "INTERNAL_ERROR"
        case .notImplemented:
            return "NOT_IMPLEMENTED"
        }
    }

    // MARK: - Error Description

    var errorDescription: String? {
        switch self {
        case .serverStartFailed:
            return "Failed to start server"
        case .serverStopFailed:
            return "Failed to stop server"
        case .invalidRequest:
            return "Invalid request"
        case .missingBody:
            return "Request body is missing"
        case .decodingFailed(let details):
            return "Failed to decode request: \(details)"
        case .encodingFailed(let details):
            return "Failed to encode response: \(details)"
        case .unauthorized:
            return "Invalid or missing bearer token"
        case .forbidden:
            return "Access forbidden"
        case .notFound(let resource):
            return "Resource not found: \(resource)"
        case .methodNotAllowed:
            return "HTTP method not allowed"
        case .rateLimited(let message):
            return message
        case .handlerNotAvailable:
            return "Request handler not available"
        case .handlerFailed(let details):
            return details
        case .streamStartFailed(let details):
            return "Stream start failed: \(details)"
        case .streamStopFailed(let details):
            return "Stream stop failed: \(details)"
        case .cameraUpdateFailed(let details):
            return "Camera update failed: \(details)"
        case .measureFailed(let details):
            return "Measurement failed: \(details)"
        case .invalidAlias(let details):
            return details
        case .aliasUpdateFailed(let details):
            return "Alias update failed: \(details)"
        case .torchUpdateFailed(let details):
            return "Torch update failed: \(details)"
        case .videoSettingsUpdateFailed(let details):
            return "Video settings update failed: \(details)"
        case .internalError(let details):
            return "Internal error: \(details)"
        case .notImplemented(let feature):
            return "Not implemented: \(feature)"
        }
    }

    // MARK: - Convert to HTTPResponse

    /// Converts error to HTTPResponse with proper status and error payload
    func toHTTPResponse(using codec: JSONCodec = .shared) -> HTTPResponse {
        let errorResponse = ErrorResponse(
            code: self.code,
            message: self.errorDescription ?? "Unknown error"
        )

        let jsonData = (try? codec.encode(errorResponse)) ?? Data()
        return HTTPResponse(status: self.httpStatus, body: jsonData)
    }
}
