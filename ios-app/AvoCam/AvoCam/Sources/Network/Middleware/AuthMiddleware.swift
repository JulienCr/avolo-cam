//
//  AuthMiddleware.swift
//  AvoCam
//
//  Bearer token authentication middleware
//

import Foundation

/// Middleware that validates Bearer token authentication
final class AuthMiddleware: HTTPMiddleware {
    private let bearerToken: String
    private var isEnabled: Bool

    init(bearerToken: String, isEnabled: Bool = false) {
        self.bearerToken = bearerToken
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        // Skip OPTIONS requests (CORS preflight)
        guard method != "OPTIONS" else { return nil }

        // Skip if auth is disabled
        guard isEnabled else { return nil }

        // Validate Bearer token
        guard let authHeader = headers["Authorization"],
              authHeader == "Bearer \(bearerToken)" else {
            print("⚠️ Authentication failed for \(method) \(path)")
            return HTTPResponse(
                status: 401,
                body: errorJSON(code: "UNAUTHORIZED", message: "Invalid or missing bearer token")
            )
        }

        return nil  // Continue to next middleware/handler
    }

    private func errorJSON(code: String, message: String) -> Data {
        let error = ["code": code, "message": message]
        return (try? JSONSerialization.data(withJSONObject: error)) ?? Data()
    }
}
