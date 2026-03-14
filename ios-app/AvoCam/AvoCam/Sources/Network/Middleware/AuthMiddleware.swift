//
//  AuthMiddleware.swift
//  AvoCam
//
//  Bearer token authentication middleware
//

import Foundation
import os

/// Middleware that validates Bearer token authentication
final class AuthMiddleware: HTTPMiddleware {
    private let bearerToken: String
    private let isEnabled: OSAllocatedUnfairLock<Bool>

    init(bearerToken: String, isEnabled: Bool = false) {
        self.bearerToken = bearerToken
        self.isEnabled = OSAllocatedUnfairLock(initialState: isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled.withLock { $0 = enabled }
    }

    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        // Skip OPTIONS requests (CORS preflight)
        guard method != "OPTIONS" else { return nil }

        // Skip if auth is disabled
        guard isEnabled.withLock({ $0 }) else { return nil }

        // Validate Bearer token
        guard let authHeader = headers["Authorization"],
              authHeader == "Bearer \(bearerToken)" else {
            print("⚠️ Authentication failed for \(method) \(path)")
            return HTTPResponse.error(status: 401, code: "UNAUTHORIZED", message: "Invalid or missing bearer token")
        }

        return nil  // Continue to next middleware/handler
    }
}
