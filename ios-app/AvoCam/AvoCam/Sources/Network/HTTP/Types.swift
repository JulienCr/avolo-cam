//
//  Types.swift
//  AvoCam
//
//  Core HTTP types and protocols for request/response handling
//

import Foundation

// MARK: - HTTP Request

/// Abstract HTTP request (decoupled from NIO)
struct HTTPRequest {
    let method: HTTPMethod
    let path: String
    let headers: HTTPHeadersMap
    let body: Data?

    init(method: HTTPMethod, path: String, headers: HTTPHeadersMap = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Extract Authorization header
    func authorizationHeader() -> String? {
        return headers["Authorization"] ?? headers["authorization"]
    }

    /// Decode JSON body to a Codable type
    func decodeBody<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder) throws -> T {
        guard let body = body else {
            throw HTTPError.missingBody
        }
        return try decoder.decode(type, from: body)
    }
}

// MARK: - HTTP Response

/// Abstract HTTP response (decoupled from NIO)
struct HTTPResponse {
    let status: HTTPStatus
    let headers: HTTPHeadersMap
    let body: Data

    init(status: HTTPStatus, headers: HTTPHeadersMap = [:], body: Data = Data()) {
        self.status = status
        var allHeaders = headers

        // Add CORS headers if not present
        if allHeaders["Access-Control-Allow-Origin"] == nil {
            allHeaders["Access-Control-Allow-Origin"] = "*"
        }

        // Add Content-Type if not present
        if allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = "application/json"
        }

        self.headers = allHeaders
        self.body = body
    }
}

// MARK: - HTTP Status

enum HTTPStatus: Int {
    case ok = 200
    case noContent = 204
    case badRequest = 400
    case unauthorized = 401
    case notFound = 404
    case requestTimeout = 408
    case tooManyRequests = 429
    case internalServerError = 500
    case notImplemented = 501
    case badGateway = 502
}

// MARK: - HTTP Method

enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case DELETE
    case OPTIONS
}

// MARK: - HTTP Headers Map

typealias HTTPHeadersMap = [String: String]

// MARK: - HTTP Error

enum HTTPError: Error {
    case missingBody
    case decodingFailed(Error)
    case encodingFailed(Error)
}

// MARK: - HTTP Response Encodable Protocol

/// Protocol for types that can be encoded into HTTPResponse
protocol HTTPResponseEncodable {
    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse
}

// MARK: - Convenience Response Types

/// JSON response wrapper
struct JSONResponse<T: Encodable>: HTTPResponseEncodable {
    let status: HTTPStatus
    let data: T
    let headers: HTTPHeadersMap

    init(status: HTTPStatus = .ok, data: T, headers: HTTPHeadersMap = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }

    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse {
        let jsonData = try encoder.encode(data)
        return HTTPResponse(status: status, headers: headers, body: jsonData)
    }
}

/// Empty response
struct EmptyResponse: HTTPResponseEncodable {
    let status: HTTPStatus

    init(status: HTTPStatus = .noContent) {
        self.status = status
    }

    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse {
        return HTTPResponse(status: status, body: Data())
    }
}

/// Success message response
struct SuccessResponse: HTTPResponseEncodable, Encodable {
    let success: Bool = true
    let message: String

    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse {
        let jsonData = try encoder.encode(self)
        return HTTPResponse(status: .ok, body: jsonData)
    }
}

// MARK: - Route Handler Type

/// Async route handler function signature
typealias RouteHandler = (HTTPRequest) async throws -> HTTPResponseEncodable
