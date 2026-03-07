//
//  StringResolutionTests.swift
//  AvoCamTests
//
//  Tests for String+Resolution parsing extension
//

import XCTest
@testable import AvoCam

final class StringResolutionTests: XCTestCase {

    // MARK: - Valid Resolutions

    func testParse1080p() {
        let result = "1920x1080".parseResolution()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 1920)
        XCTAssertEqual(result?.height, 1080)
    }

    func testParse720p() {
        let result = "1280x720".parseResolution()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 1280)
        XCTAssertEqual(result?.height, 720)
    }

    func testParse4K() {
        let result = "3840x2160".parseResolution()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 3840)
        XCTAssertEqual(result?.height, 2160)
    }

    func testParse2K() {
        let result = "2560x1440".parseResolution()
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 2560)
        XCTAssertEqual(result?.height, 1440)
    }

    // MARK: - Invalid Inputs

    func testInvalidStringReturnsNil() {
        XCTAssertNil("invalid".parseResolution())
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil("".parseResolution())
    }

    func testSingleNumberReturnsNil() {
        XCTAssertNil("1920".parseResolution())
    }

    func testWrongSeparatorReturnsNil() {
        XCTAssertNil("1920X1080".parseResolution())
    }

    func testNonNumericPartsReturnsNil() {
        XCTAssertNil("widexhigh".parseResolution())
    }

    func testTooManyPartsReturnsNil() {
        XCTAssertNil("1920x1080x720".parseResolution())
    }
}
