//
//  AuthMiddlewareTests.swift
//  AvoCamTests
//
//  Tests for Bearer token authentication middleware
//

import XCTest
@testable import AvoCam

final class AuthMiddlewareTests: XCTestCase {

    private let testToken = "ABC123DEF456"

    // MARK: - Enabled Auth

    func testValidTokenPasses() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: true)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "GET",
            headers: ["Authorization": "Bearer ABC123DEF456"],
            body: nil
        )

        XCTAssertNil(result, "Valid token should pass through (nil response)")
    }

    func testInvalidTokenReturns401() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: true)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "GET",
            headers: ["Authorization": "Bearer WRONG_TOKEN"],
            body: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, 401)
    }

    func testMissingAuthHeaderReturns401() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: true)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "GET",
            headers: [:],
            body: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, 401)
    }

    func testMalformedAuthHeaderReturns401() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: true)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "GET",
            headers: ["Authorization": "Basic dXNlcjpwYXNz"],
            body: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, 401)
    }

    // MARK: - Disabled Auth

    func testDisabledAuthPassesAll() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: false)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "GET",
            headers: [:],
            body: nil
        )

        XCTAssertNil(result, "Disabled auth should pass all requests")
    }

    // MARK: - OPTIONS Bypass

    func testOPTIONSBypassesAuth() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: true)

        let result = await middleware.handle(
            path: "/api/v1/status",
            method: "OPTIONS",
            headers: [:],
            body: nil
        )

        XCTAssertNil(result, "OPTIONS should bypass auth for CORS preflight")
    }

    // MARK: - setEnabled

    func testSetEnabledToggle() async {
        let middleware = AuthMiddleware(bearerToken: testToken, isEnabled: false)

        // Should pass without auth
        let result1 = await middleware.handle(path: "/test", method: "GET", headers: [:], body: nil)
        XCTAssertNil(result1)

        // Enable auth
        middleware.setEnabled(true)

        // Should now require auth
        let result2 = await middleware.handle(path: "/test", method: "GET", headers: [:], body: nil)
        XCTAssertEqual(result2?.status, 401)
    }
}
