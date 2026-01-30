//
//  HTTPResponse+Convenience.swift
//  AvoCam
//
//  Convenience factory methods for HTTPResponse
//

import Foundation

extension HTTPResponse {
    static func success(message: String) -> HTTPResponse {
        let body = ["success": true, "message": message] as [String: Any]
        return HTTPResponse(status: 200, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    static func badRequest(code: String, message: String) -> HTTPResponse {
        return error(status: 400, code: code, message: message)
    }

    static func internalError(code: String = "INTERNAL_ERROR", message: String = "Internal server error") -> HTTPResponse {
        return error(status: 500, code: code, message: message)
    }

    static func error(status: Int, code: String, message: String) -> HTTPResponse {
        let body = ["code": code, "message": message]
        return HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        guard let data = try? JSONEncoder().encode(value) else {
            return internalError(code: "ENCODING_ERROR", message: "Failed to encode response")
        }
        return HTTPResponse(status: status, body: data)
    }

    static func html(_ content: Data) -> HTTPResponse {
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: content)
    }
}
