//
//  CameraControlService.swift
//  AvoCam
//
//  Protocol for camera control service abstraction
//

import Foundation

protocol CameraControlService: AnyObject {
    func updateCameraSettings(_ settings: CameraSettingsRequest) async throws
    func getCapabilities() async -> [Capability]
    func measureWhiteBalance() async throws -> (sceneCCT_K: Int, tint: Double)
    func getCurrentFocusState() async -> (mode: FocusMode, distance: Double?)
}
