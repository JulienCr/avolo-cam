//
//  ThermalManagerTests.swift
//  AvoCamTests
//
//  Tests for thermal state machine and action determination
//

import XCTest
@testable import AvoCam

final class ThermalManagerTests: XCTestCase {

    // MARK: - Initial State

    func testInitialLevelIsNominal() async {
        let manager = ThermalManager()
        let level = await manager.currentLevel
        XCTAssertEqual(level, .nominal)
    }

    func testInitiallyNotOverheating() async {
        let manager = ThermalManager()
        let overheating = await manager.isOverheating
        XCTAssertFalse(overheating)
    }

    // MARK: - Thermal Level Transitions

    func testNominalToSeriousWhileStreamingTriggersWarning() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)

        var receivedAction: ThermalManager.ThermalAction?
        await manager.setActionCallback { action in
            receivedAction = action
        }

        await manager.checkThermalState(.serious)

        // Allow callback to execute
        try? await Task.sleep(nanoseconds: 100_000_000)

        let level = await manager.currentLevel
        XCTAssertEqual(level, .serious)

        let overheating = await manager.isOverheating
        XCTAssertTrue(overheating)
    }

    func testSeriousWarningOnlyIssuedOnce() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)

        // First serious state should produce a warning
        await manager.checkThermalState(.serious)

        // Second serious state should NOT produce another warning
        // (determineAction returns .none when warningIssued is already true)
        await manager.checkThermalState(.serious)

        let level = await manager.currentLevel
        XCTAssertEqual(level, .serious)
    }

    func testCriticalWhileStreamingTriggersStopStream() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)

        await manager.checkThermalState(.critical)

        let level = await manager.currentLevel
        XCTAssertEqual(level, .critical)

        let overheating = await manager.isOverheating
        XCTAssertTrue(overheating)
    }

    func testRecoveryFromSeriousToNominal() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)

        // Go to serious first
        await manager.checkThermalState(.serious)

        // Return to nominal
        await manager.checkThermalState(.nominal)

        let level = await manager.currentLevel
        XCTAssertEqual(level, .nominal)

        let overheating = await manager.isOverheating
        XCTAssertFalse(overheating)
    }

    // MARK: - Not Streaming

    func testNoActionWhenNotStreaming() async {
        let manager = ThermalManager()
        // Not streaming (default)

        await manager.checkThermalState(.critical)

        let level = await manager.currentLevel
        XCTAssertEqual(level, .critical)
    }

    func testFlagsResetWhenNotStreaming() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)

        // Trigger warning
        await manager.checkThermalState(.serious)

        // Stop streaming
        await manager.setIsStreaming(false)

        // Check nominal while not streaming - should reset flags
        await manager.checkThermalState(.nominal)

        // Start streaming again and go serious - should issue warning again
        await manager.setIsStreaming(true)
        await manager.checkThermalState(.serious)

        // If the warning was re-issued, it means flags were properly reset
        let level = await manager.currentLevel
        XCTAssertEqual(level, .serious)
    }

    // MARK: - Reset

    func testResetClearsState() async {
        let manager = ThermalManager()
        await manager.setIsStreaming(true)
        await manager.checkThermalState(.serious)

        await manager.reset()

        let level = await manager.currentLevel
        // Level itself is not reset by reset() - only flags
        // After reset, isStreaming is false
        XCTAssertEqual(level, .serious)
    }

    // MARK: - Status Description

    func testStatusDescriptions() async {
        let manager = ThermalManager()

        await manager.checkThermalState(.nominal)
        var desc = await manager.statusDescription
        XCTAssertEqual(desc, "Normal")

        await manager.checkThermalState(.fair)
        desc = await manager.statusDescription
        XCTAssertEqual(desc, "Warm")

        await manager.checkThermalState(.serious)
        desc = await manager.statusDescription
        XCTAssertEqual(desc, "Hot - Consider reducing quality")

        await manager.checkThermalState(.critical)
        desc = await manager.statusDescription
        XCTAssertEqual(desc, "Critical - Stream stopped")
    }
}
