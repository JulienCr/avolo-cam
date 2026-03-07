//
//  NetworkRequestHandler.swift
//  AvoCam
//
//  Protocol for handling network requests from the HTTP/WebSocket server
//

import Foundation

protocol NetworkRequestHandler: AnyObject {
    func handleStreamStart(_ request: StreamStartRequest) async throws
    func handleStreamStop() async throws
    func handleCameraSettings(_ settings: CameraSettingsRequest) async throws
    func handleGetStatus() async -> StatusResponse
    func handleGetCapabilities() async -> [Capability]
    func handleGetVideoSettings() async -> VideoSettingsResponse
    func handleUpdateVideoSettings(_ request: VideoSettingsUpdateRequest) async throws
    func handleScreenBrightness(_ request: ScreenBrightnessRequest)
    func handleMeasureWhiteBalance() async throws -> WhiteBalanceMeasureResponse
    func handleUpdateAlias(_ request: AliasUpdateRequest) async throws -> AliasUpdateResponse
    func handleGetTorchLevel() async -> TorchLevelResponse
    func handleUpdateTorchLevel(_ request: TorchLevelUpdateRequest) async throws -> TorchLevelResponse
}
