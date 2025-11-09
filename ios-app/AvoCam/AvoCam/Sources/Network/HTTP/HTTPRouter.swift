//
//  HTTPRouter.swift
//  AvoCam
//
//  Declarative HTTP router with middleware support
//

import Foundation

// MARK: - Route Definition

struct Route {
    let method: HTTPMethod
    let path: String
    let handler: RouteHandler

    init(method: HTTPMethod, path: String, handler: @escaping RouteHandler) {
        self.method = method
        self.path = path
        self.handler = handler
    }
}

// MARK: - HTTP Router

class HTTPRouter {
    // MARK: - Properties

    private var routes: [Route] = []
    private let middlewareChain: MiddlewareChain
    private let codec: JSONCodec

    // MARK: - Initialization

    init(middlewares: [HTTPMiddleware] = [], codec: JSONCodec = .shared) {
        self.middlewareChain = MiddlewareChain(middlewares: middlewares)
        self.codec = codec
    }

    // MARK: - Route Registration

    /// Register a route with method, path, and handler
    func register(
        _ method: HTTPMethod,
        _ path: String,
        handler: @escaping RouteHandler
    ) {
        let route = Route(method: method, path: path, handler: handler)
        routes.append(route)
    }

    /// Register a GET route
    func get(_ path: String, handler: @escaping RouteHandler) {
        register(.GET, path, handler: handler)
    }

    /// Register a POST route
    func post(_ path: String, handler: @escaping RouteHandler) {
        register(.POST, path, handler: handler)
    }

    /// Register a PUT route
    func put(_ path: String, handler: @escaping RouteHandler) {
        register(.PUT, path, handler: handler)
    }

    /// Register a DELETE route
    func delete(_ path: String, handler: @escaping RouteHandler) {
        register(.DELETE, path, handler: handler)
    }

    // MARK: - Request Routing

    /// Route an HTTP request through middleware and to the appropriate handler
    func route(request: HTTPRequest) async -> HTTPResponse {
        do {
            // Execute middleware chain
            let result = try await middlewareChain.execute(request: request) { request in
                // Find matching route
                guard let route = findRoute(method: request.method, path: request.path) else {
                    throw NetworkError.notFound("Endpoint not found: \(request.method.rawValue) \(request.path)")
                }

                // Execute handler
                return try await route.handler(request)
            }

            // Convert result to HTTPResponse
            return try result.toHTTPResponse(using: codec.encoder)

        } catch let error as NetworkError {
            // Convert NetworkError to HTTPResponse
            return error.toHTTPResponse(using: codec)

        } catch {
            // Convert generic error to HTTPResponse
            let networkError = NetworkError.internalError(error.localizedDescription)
            return networkError.toHTTPResponse(using: codec)
        }
    }

    // MARK: - Route Matching

    private func findRoute(method: HTTPMethod, path: String) -> Route? {
        return routes.first { route in
            route.method == method && route.path == path
        }
    }
}
