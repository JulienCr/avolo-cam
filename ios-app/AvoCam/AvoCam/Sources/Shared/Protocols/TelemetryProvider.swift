//
//  TelemetryProvider.swift
//  AvoCam
//
//  Protocol for telemetry provider abstraction
//

import Foundation

protocol TelemetryProvider: AnyObject {
    func getCurrentTelemetry() async -> Telemetry
}
