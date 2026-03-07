//
//  HTTPRouterTests.swift
//  AvoCamTests
//
//  Tests for HTTP route matching and middleware chain
//

import XCTest
@testable import AvoCam

final class HTTPRouterTests: XCTestCase {

    // MARK: - Route Matching

    func testGetRouteMatches() async {
        let router = HTTPRouter()
        router.get("/api/v1/status") { _, _, _, _ in
            return .success(message: "OK")
        }

        let response = await router.route(path: "/api/v1/status", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(response.status, 200)
    }

    func testPostRouteMatches() async {
        let router = HTTPRouter()
        router.post("/api/v1/stream/start") { _, _, _, _ in
            return .success(message: "Stream started")
        }

        let response = await router.route(path: "/api/v1/stream/start", method: "POST", headers: [:], body: nil)
        XCTAssertEqual(response.status, 200)
    }

    func testPutRouteMatches() async {
        let router = HTTPRouter()
        router.put("/api/v1/settings") { _, _, _, _ in
            return .success(message: "Updated")
        }

        let response = await router.route(path: "/api/v1/settings", method: "PUT", headers: [:], body: nil)
        XCTAssertEqual(response.status, 200)
    }

    func testUnknownRouteReturns404() async {
        let router = HTTPRouter()
        router.get("/api/v1/status") { _, _, _, _ in
            return .success(message: "OK")
        }

        let response = await router.route(path: "/api/v1/nonexistent", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(response.status, 404)

        let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: String]
        XCTAssertEqual(body?["code"], "NOT_FOUND")
    }

    func testWrongMethodReturns404() async {
        let router = HTTPRouter()
        router.get("/api/v1/status") { _, _, _, _ in
            return .success(message: "OK")
        }

        let response = await router.route(path: "/api/v1/status", method: "POST", headers: [:], body: nil)
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - Middleware

    func testMiddlewareCanShortCircuit() async {
        let router = HTTPRouter()
        router.use(BlockingMiddleware())
        router.get("/api/v1/status") { _, _, _, _ in
            return .success(message: "Should not reach here")
        }

        let response = await router.route(path: "/api/v1/status", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(response.status, 403)
    }

    func testMiddlewarePassThrough() async {
        let router = HTTPRouter()
        router.use(PassThroughMiddleware())
        router.get("/api/v1/status") { _, _, _, _ in
            return .success(message: "Reached handler")
        }

        let response = await router.route(path: "/api/v1/status", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(response.status, 200)
    }

    func testMiddlewareChainOrder() async {
        let router = HTTPRouter()
        let tracker = OrderTracker()

        router.use(TrackingMiddleware(id: "first", tracker: tracker))
        router.use(TrackingMiddleware(id: "second", tracker: tracker))
        router.get("/test") { _, _, _, _ in
            return .success(message: "OK")
        }

        _ = await router.route(path: "/test", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(tracker.order, ["first", "second"])
    }

    // MARK: - Route handler receives parameters

    func testRouteHandlerReceivesBody() async {
        let router = HTTPRouter()
        let expectedBody = "{\"test\": true}".data(using: .utf8)!

        router.post("/api/v1/test") { path, method, headers, body in
            XCTAssertEqual(path, "/api/v1/test")
            XCTAssertEqual(method, "POST")
            XCTAssertNotNil(body)
            return .success(message: "OK")
        }

        let response = await router.route(
            path: "/api/v1/test",
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: expectedBody
        )
        XCTAssertEqual(response.status, 200)
    }
}

// MARK: - Test Helpers

private final class BlockingMiddleware: HTTPMiddleware {
    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        return .error(status: 403, code: "FORBIDDEN", message: "Blocked")
    }
}

private final class PassThroughMiddleware: HTTPMiddleware {
    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        return nil
    }
}

private final class OrderTracker: @unchecked Sendable {
    var order: [String] = []
}

private final class TrackingMiddleware: HTTPMiddleware {
    let id: String
    let tracker: OrderTracker

    init(id: String, tracker: OrderTracker) {
        self.id = id
        self.tracker = tracker
    }

    func handle(path: String, method: String, headers: [String: String], body: Data?) async -> HTTPResponse? {
        tracker.order.append(id)
        return nil
    }
}
