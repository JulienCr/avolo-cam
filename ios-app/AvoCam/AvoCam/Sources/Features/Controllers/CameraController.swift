//
//  CameraController.swift
//  AvoCam
//
//  Handles camera settings, white balance, alias, and screen brightness endpoints
//

import Foundation

// MARK: - Camera Controller

class CameraController {
    // MARK: - Properties

    private weak var handler: NetworkRequestHandler?

    // MARK: - Initialization

    init(handler: NetworkRequestHandler?) {
        self.handler = handler
    }

    // MARK: - Camera Settings Endpoints

    /// POST /api/v1/camera
    func updateCameraSettings(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let settings = try request.decodeBody(
            CameraSettingsRequest.self,
            using: JSONCodec.shared.decoder
        )

        do {
            try await handler.handleCameraSettings(settings)
            return SuccessResponse(message: "Camera settings updated")
        } catch {
            throw NetworkError.cameraUpdateFailed(error.localizedDescription)
        }
    }

    // MARK: - White Balance Endpoints

    /// POST /api/v1/camera/wb/measure
    func measureWhiteBalance(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        do {
            let result = try await handler.handleMeasureWhiteBalance()
            print("✅ White balance measured: SceneCCT_K = \(result.sceneCCT_K)K (physical), tint = \(String(format: "%.1f", result.tint))")
            return JSONResponse(data: result)
        } catch {
            throw NetworkError.measureFailed(error.localizedDescription)
        }
    }

    // MARK: - Alias Endpoints

    /// PUT /api/v1/settings/alias
    func updateAlias(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let aliasRequest = try request.decodeBody(
            AliasUpdateRequest.self,
            using: JSONCodec.shared.decoder
        )

        // Validate alias (no empty strings, reasonable length)
        let trimmedAlias = aliasRequest.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty, trimmedAlias.count <= 64 else {
            throw NetworkError.invalidAlias("Alias must be 1-64 characters")
        }

        do {
            let result = try await handler.handleUpdateAlias(aliasRequest)
            print("✅ Alias updated to: \(result.alias)")
            return JSONResponse(data: result)
        } catch {
            throw NetworkError.aliasUpdateFailed(error.localizedDescription)
        }
    }

    // MARK: - Screen Brightness Endpoint

    /// POST /api/v1/screen/brightness
    func updateScreenBrightness(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let brightnessRequest = try request.decodeBody(
            ScreenBrightnessRequest.self,
            using: JSONCodec.shared.decoder
        )

        handler.handleScreenBrightness(brightnessRequest)
        return SuccessResponse(message: "Screen brightness updated")
    }
}
