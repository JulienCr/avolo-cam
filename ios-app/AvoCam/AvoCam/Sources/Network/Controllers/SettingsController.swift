//
//  SettingsController.swift
//  AvoCam
//
//  HTTP controller for settings endpoints
//

import Foundation

/// Controller for video settings, alias, and screen brightness endpoints
final class SettingsController: APIController {
    private weak var requestHandler: NetworkRequestHandler?

    init(requestHandler: NetworkRequestHandler) {
        self.requestHandler = requestHandler
    }

    func registerRoutes(router: HTTPRouter) {
        router.get("/api/v1/video/settings") { [weak self] _, _, _, _ in
            await self?.handleGetVideoSettings() ?? HTTPResponse.internalError()
        }

        router.put("/api/v1/video/settings") { [weak self] _, _, _, body in
            await self?.handlePutVideoSettings(body: body) ?? HTTPResponse.internalError()
        }

        router.put("/api/v1/settings/alias") { [weak self] _, _, _, body in
            await self?.handleUpdateAlias(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/screen/brightness") { [weak self] _, _, _, body in
            self?.handleScreenBrightness(body: body) ?? HTTPResponse.internalError()
        }
    }

    private func handleGetVideoSettings() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let settings = await handler.handleGetVideoSettings()
        return HTTPResponse.json(settings)
    }

    private func handlePutVideoSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(VideoSettingsUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid video settings request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            try await handler.handleUpdateVideoSettings(request)
            return HTTPResponse.success(message: "Video settings updated")
        } catch {
            return HTTPResponse.error(status: 500, code: "VIDEO_SETTINGS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleUpdateAlias(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(AliasUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid alias update request")
        }

        // Validate alias (no empty strings, reasonable length)
        let trimmedAlias = request.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlias.isEmpty, trimmedAlias.count <= 64 else {
            return HTTPResponse.badRequest(code: "INVALID_ALIAS", message: "Alias must be 1-64 characters")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            let result = try await handler.handleUpdateAlias(request)
            print("✅ Alias updated to: \(result.alias)")
            return HTTPResponse.json(result)
        } catch {
            print("❌ Alias update failed: \(error.localizedDescription)")
            return HTTPResponse.error(status: 500, code: "ALIAS_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleScreenBrightness(body: Data?) -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(ScreenBrightnessRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid screen brightness request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        handler.handleScreenBrightness(request)
        return HTTPResponse.success(message: "Screen brightness updated")
    }
}
