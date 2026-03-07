//
//  RateLimitMiddleware.swift
//  AvoCam
//
//  Rate limiting middleware for camera control endpoints
//

import Foundation

/// Middleware that rate limits camera setting updates
final class RateLimitMiddleware: HTTPMiddleware {
    private var lastCameraUpdateTime: Date = Date.distantPast
    private let minInterval: TimeInterval

    init(minInterval: TimeInterval = 0.05) {  // 50ms default
        self.minInterval = minInterval
    }

    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        // Only rate limit camera endpoints
        guard path.contains("/camera") else { return nil }

        let now = Date()
        if now.timeIntervalSince(lastCameraUpdateTime) < minInterval {
            return .error(status: 429, code: "RATE_LIMITED", message: "Too many camera updates, wait \(Int(minInterval * 1000))ms")
        }

        lastCameraUpdateTime = now
        return nil
    }
}
