//
//  HTTPMiddleware.swift
//  AvoCam
//
//  HTTP middleware protocol for request interception
//

import Foundation

/// Protocol for HTTP middleware that can intercept requests
protocol HTTPMiddleware {
    /// Handle a request. Return HTTPResponse to short-circuit, or nil to continue chain.
    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse?
}
