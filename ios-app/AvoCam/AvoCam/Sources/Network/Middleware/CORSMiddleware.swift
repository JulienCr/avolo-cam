//
//  CORSMiddleware.swift
//  AvoCam
//
//  CORS middleware for handling preflight requests
//

import Foundation

/// Middleware that handles CORS preflight requests
final class CORSMiddleware: HTTPMiddleware {
    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        // Handle OPTIONS preflight
        guard method == "OPTIONS" else { return nil }

        return HTTPResponse(
            status: 200,
            headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, Authorization",
                "Access-Control-Max-Age": "86400"
            ],
            body: Data()
        )
    }
}
