//
//  StatusController.swift
//  AvoCam
//
//  Handles status, capabilities, video settings, and torch endpoints
//

import Foundation

// MARK: - Status Controller

class StatusController {
    // MARK: - Properties

    private weak var handler: NetworkRequestHandler?

    // MARK: - Initialization

    init(handler: NetworkRequestHandler?) {
        self.handler = handler
    }

    // MARK: - Status Endpoints

    /// GET /api/v1/status
    func getStatus(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let status = await handler.handleGetStatus()
        return JSONResponse(data: status)
    }

    /// GET /api/v1/capabilities
    func getCapabilities(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let capabilities = await handler.handleGetCapabilities()
        return JSONResponse(data: capabilities)
    }

    // MARK: - Video Settings Endpoints

    /// GET /api/v1/video/settings
    func getVideoSettings(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let settings = await handler.handleGetVideoSettings()
        return JSONResponse(data: settings)
    }

    /// PUT /api/v1/video/settings
    func updateVideoSettings(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let updateRequest = try request.decodeBody(
            VideoSettingsUpdateRequest.self,
            using: JSONCodec.shared.decoder
        )

        do {
            try await handler.handleUpdateVideoSettings(updateRequest)
            return SuccessResponse(message: "Video settings updated")
        } catch {
            throw NetworkError.videoSettingsUpdateFailed(error.localizedDescription)
        }
    }

    // MARK: - Torch Endpoints

    /// GET /api/v1/torch/level
    func getTorchLevel(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let response = await handler.handleGetTorchLevel()
        return JSONResponse(data: response)
    }

    /// PUT /api/v1/torch/level
    func updateTorchLevel(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let updateRequest = try request.decodeBody(
            TorchLevelUpdateRequest.self,
            using: JSONCodec.shared.decoder
        )

        do {
            let response = try await handler.handleUpdateTorchLevel(updateRequest)
            print("✅ Torch level updated to: \(response.currentLevel)")
            return JSONResponse(data: response)
        } catch {
            throw NetworkError.torchUpdateFailed(error.localizedDescription)
        }
    }

    // MARK: - Logs Endpoint

    /// GET /api/v1/logs.zip
    func downloadLogs(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        // TODO: Implement rotating logs and zip creation
        throw NetworkError.notImplemented("Logs download not yet implemented")
    }
}
