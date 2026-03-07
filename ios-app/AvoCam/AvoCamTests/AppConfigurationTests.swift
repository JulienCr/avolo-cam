//
//  AppConfigurationTests.swift
//  AvoCamTests
//
//  Tests for AppConfiguration logic
//

import XCTest
@testable import AvoCam

final class AppConfigurationTests: XCTestCase {

    // MARK: - generateDefaultAlias

    func testGenerateDefaultAliasFormat() {
        let alias = AppConfiguration.generateDefaultAlias()
        XCTAssertTrue(alias.hasPrefix("AVOLO-CAM-"), "Alias should start with AVOLO-CAM-, got: \(alias)")
        let suffix = String(alias.dropFirst("AVOLO-CAM-".count))
        XCTAssertEqual(suffix.count, 2, "Hex suffix should be 2 characters")
        XCTAssertNotNil(UInt8(suffix, radix: 16), "Suffix should be valid hex")
    }

    func testGenerateDefaultAliasRandomness() {
        let aliases = Set((0..<20).map { _ in AppConfiguration.generateDefaultAlias() })
        XCTAssertGreaterThan(aliases.count, 1, "Multiple calls should produce different aliases")
    }

    // MARK: - generateToken

    func testGenerateTokenFormat() {
        let token = AppConfiguration.generateToken()
        XCTAssertEqual(token.count, 32, "Token should be 32 hex characters (UUID without dashes)")
        XCTAssertFalse(token.contains("-"), "Token should not contain dashes")
    }

    func testGenerateTokenUniqueness() {
        let token1 = AppConfiguration.generateToken()
        let token2 = AppConfiguration.generateToken()
        XCTAssertNotEqual(token1, token2, "Consecutive tokens should be unique")
    }

    // MARK: - withAlias

    func testWithAliasReturnsUpdatedConfig() {
        let config = AppConfiguration(
            cameraAlias: "AVOLO-CAM-01",
            bearerToken: "testtoken",
            isAuthenticationEnabled: false,
            serverPort: 8888
        )

        let updated = config.withAlias("AVOLO-CAM-NEW")

        XCTAssertEqual(updated.cameraAlias, "AVOLO-CAM-NEW")
        XCTAssertEqual(updated.bearerToken, "testtoken")
        XCTAssertEqual(updated.isAuthenticationEnabled, false)
        XCTAssertEqual(updated.serverPort, 8888)
    }

    // MARK: - withAuthenticationToggled

    func testWithAuthenticationToggledFromDisabled() {
        let config = AppConfiguration(
            cameraAlias: "AVOLO-CAM-01",
            bearerToken: "testtoken",
            isAuthenticationEnabled: false,
            serverPort: 8888
        )

        let toggled = config.withAuthenticationToggled()

        XCTAssertTrue(toggled.isAuthenticationEnabled)
        XCTAssertEqual(toggled.cameraAlias, "AVOLO-CAM-01")
    }

    func testWithAuthenticationToggledFromEnabled() {
        let config = AppConfiguration(
            cameraAlias: "AVOLO-CAM-01",
            bearerToken: "testtoken",
            isAuthenticationEnabled: true,
            serverPort: 8888
        )

        let toggled = config.withAuthenticationToggled()

        XCTAssertFalse(toggled.isAuthenticationEnabled)
    }

    // MARK: - Constants

    func testDefaultServerPort() {
        XCTAssertEqual(AppConfiguration.defaultServerPort, 8888)
    }
}
