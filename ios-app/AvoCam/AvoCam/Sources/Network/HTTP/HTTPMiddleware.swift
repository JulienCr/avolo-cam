//
//  HTTPMiddleware.swift
//  AvoCam
//
//  Middleware components for HTTP request processing
//

import Foundation

// MARK: - Middleware Protocol

/// Middleware processes requests and can short-circuit or pass through
protocol HTTPMiddleware {
    func process(
        request: HTTPRequest,
        next: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable
}

// MARK: - CORS Middleware

/// Handles CORS preflight (OPTIONS) requests
struct CORSMiddleware: HTTPMiddleware {
    func process(
        request: HTTPRequest,
        next: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable {
        // Handle OPTIONS (preflight) request
        if request.method == .OPTIONS {
            return CORSPreflightResponse()
        }

        // Pass through to next middleware
        return try await next(request)
    }
}

/// CORS preflight response
private struct CORSPreflightResponse: HTTPResponseEncodable {
    func toHTTPResponse(using encoder: JSONEncoder) throws -> HTTPResponse {
        return HTTPResponse(
            status: .ok,
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

// MARK: - Auth Middleware

/// Bearer token authentication middleware
struct AuthMiddleware: HTTPMiddleware {
    let bearerToken: String
    let enabled: Bool

    func process(
        request: HTTPRequest,
        next: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable {
        guard enabled else {
            return try await next(request)
        }

        // Extract authorization header
        guard let authHeader = request.authorizationHeader() else {
            throw NetworkError.unauthorized
        }

        // Validate bearer token (constant-time comparison)
        let expectedValue = "Bearer \(bearerToken)"
        guard authHeader.count == expectedValue.count,
              authHeader == expectedValue else {
            throw NetworkError.unauthorized
        }

        return try await next(request)
    }
}

// MARK: - Rate Limit Middleware

/// Token bucket rate limiter
struct RateLimitMiddleware: HTTPMiddleware {
    private let pathPredicate: (String) -> Bool
    private let minInterval: TimeInterval
    private let lock = NSLock()
    private var lastRequestTime: Date = .distantPast

    init(pathPredicate: @escaping (String) -> Bool, minInterval: TimeInterval) {
        self.pathPredicate = pathPredicate
        self.minInterval = minInterval
    }

    func process(
        request: HTTPRequest,
        next: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable {
        // Check if path matches rate limit predicate
        guard pathPredicate(request.path) else {
            return try await next(request)
        }

        // Check rate limit
        lock.lock()
        let now = Date()
        let timeSinceLastRequest = now.timeIntervalSince(lastRequestTime)

        if timeSinceLastRequest < minInterval {
            lock.unlock()
            let waitMs = Int((minInterval - timeSinceLastRequest) * 1000)
            throw NetworkError.rateLimited("Too many requests, wait \(waitMs)ms")
        }

        lastRequestTime = now
        lock.unlock()

        return try await next(request)
    }
}

// MARK: - Content Type Middleware

/// Ensures JSON content-type on responses
struct ContentTypeMiddleware: HTTPMiddleware {
    func process(
        request: HTTPRequest,
        next: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable {
        // Pass through - content type is set in HTTPResponse init
        return try await next(request)
    }
}

// MARK: - Middleware Chain

/// Chains multiple middleware together
struct MiddlewareChain {
    private let middlewares: [HTTPMiddleware]

    init(middlewares: [HTTPMiddleware]) {
        self.middlewares = middlewares
    }

    /// Execute middleware chain
    func execute(
        request: HTTPRequest,
        finalHandler: @escaping (HTTPRequest) async throws -> HTTPResponseEncodable
    ) async throws -> HTTPResponseEncodable {
        var index = 0

        func next(request: HTTPRequest) async throws -> HTTPResponseEncodable {
            // If we've processed all middleware, call the final handler
            if index >= middlewares.count {
                return try await finalHandler(request)
            }

            // Process current middleware
            let middleware = middlewares[index]
            index += 1
            return try await middleware.process(request: request, next: next)
        }

        return try await next(request: request)
    }
}
