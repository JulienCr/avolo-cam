//
//  HTTPRouter.swift
//  AvoCam
//
//  Route dispatch for HTTP requests
//

import Foundation

/// HTTP route handler closure type
typealias HTTPRouteHandler = (_ path: String, _ method: String, _ headers: [String: String], _ body: Data?) async -> HTTPResponse

/// Simple HTTP router for path and method matching
final class HTTPRouter {
    private var routes: [(method: String, path: String, handler: HTTPRouteHandler)] = []
    private var middlewares: [HTTPMiddleware] = []

    /// Register a route handler
    func register(method: String, path: String, handler: @escaping HTTPRouteHandler) {
        routes.append((method: method, path: path, handler: handler))
    }

    /// Add middleware (executed in order for each request)
    func use(_ middleware: HTTPMiddleware) {
        middlewares.append(middleware)
    }

    /// Convenience methods
    func get(_ path: String, handler: @escaping HTTPRouteHandler) {
        register(method: "GET", path: path, handler: handler)
    }

    func post(_ path: String, handler: @escaping HTTPRouteHandler) {
        register(method: "POST", path: path, handler: handler)
    }

    func put(_ path: String, handler: @escaping HTTPRouteHandler) {
        register(method: "PUT", path: path, handler: handler)
    }

    /// Route a request through middleware chain and to matching handler
    func route(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse {
        // Run middleware chain first
        for middleware in middlewares {
            if let response = await middleware.handle(path: path, method: method, headers: headers, body: body) {
                return response
            }
        }

        // Find matching route
        for route in routes {
            if route.method == method && route.path == path {
                return await route.handler(path, method, headers, body)
            }
        }

        // 404 Not Found
        return HTTPResponse.error(status: 404, code: "NOT_FOUND", message: "Endpoint not found: \(method) \(path)")
    }
}
