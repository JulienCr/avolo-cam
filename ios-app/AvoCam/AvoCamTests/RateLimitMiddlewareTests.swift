//
//  RateLimitMiddlewareTests.swift
//  AvoCamTests
//
//  Tests for rate limiting middleware
//

import XCTest
@testable import AvoCam

final class RateLimitMiddlewareTests: XCTestCase {

    // MARK: - Non-Camera Paths

    func testNonCameraPathIsNotRateLimited() async {
        let middleware = RateLimitMiddleware(minInterval: 1.0)

        let result1 = await middleware.handle(path: "/api/v1/status", method: "GET", headers: [:], body: nil)
        let result2 = await middleware.handle(path: "/api/v1/status", method: "GET", headers: [:], body: nil)

        XCTAssertNil(result1)
        XCTAssertNil(result2, "Non-camera paths should never be rate limited")
    }

    // MARK: - Camera Paths

    func testFirstCameraRequestPasses() async {
        let middleware = RateLimitMiddleware(minInterval: 1.0)

        let result = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        XCTAssertNil(result, "First request should pass")
    }

    func testRapidCameraRequestsReturn429() async {
        let middleware = RateLimitMiddleware(minInterval: 1.0)

        // First request passes
        let result1 = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        XCTAssertNil(result1)

        // Immediate second request should be rate limited
        let result2 = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        XCTAssertNotNil(result2)
        XCTAssertEqual(result2?.status, 429)
    }

    func testRequestAfterIntervalPasses() async {
        // Use a very short interval so the test is fast
        let middleware = RateLimitMiddleware(minInterval: 0.01)

        let result1 = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        XCTAssertNil(result1)

        // Wait longer than the interval
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        let result2 = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        XCTAssertNil(result2, "Request after interval should pass")
    }

    // MARK: - Path Matching

    func testCameraSubpathIsRateLimited() async {
        let middleware = RateLimitMiddleware(minInterval: 1.0)

        let result1 = await middleware.handle(path: "/api/v1/camera/settings", method: "POST", headers: [:], body: nil)
        XCTAssertNil(result1)

        let result2 = await middleware.handle(path: "/api/v1/camera/settings", method: "POST", headers: [:], body: nil)
        XCTAssertEqual(result2?.status, 429)
    }

    // MARK: - 429 Response Body

    func testRateLimitResponseBody() async {
        let middleware = RateLimitMiddleware(minInterval: 0.05)

        _ = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)
        let result = await middleware.handle(path: "/api/v1/camera", method: "POST", headers: [:], body: nil)

        XCTAssertNotNil(result)
        let body = try? JSONSerialization.jsonObject(with: result!.body) as? [String: String]
        XCTAssertEqual(body?["code"], "RATE_LIMITED")
    }
}
