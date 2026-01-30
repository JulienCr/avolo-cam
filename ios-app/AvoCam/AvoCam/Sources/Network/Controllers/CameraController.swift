//
//  CameraController.swift
//  AvoCam
//
//  HTTP controller for camera control endpoints
//

import Foundation

/// Controller for camera settings, white balance, and torch endpoints
final class CameraController: APIController {
    private weak var cameraControlService: CameraControlService?
    private weak var requestHandler: NetworkRequestHandler?

    init(cameraControlService: CameraControlService, requestHandler: NetworkRequestHandler) {
        self.cameraControlService = cameraControlService
        self.requestHandler = requestHandler
    }

    func registerRoutes(router: HTTPRouter) {
        router.post("/api/v1/camera") { [weak self] _, _, _, body in
            await self?.handleCameraSettings(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/camera/wb/measure") { [weak self] _, _, _, _ in
            await self?.handleMeasureWhiteBalance() ?? HTTPResponse.internalError()
        }

        router.get("/api/v1/torch/level") { [weak self] _, _, _, _ in
            await self?.handleGetTorchLevel() ?? HTTPResponse.internalError()
        }

        router.put("/api/v1/torch/level") { [weak self] _, _, _, body in
            await self?.handlePutTorchLevel(body: body) ?? HTTPResponse.internalError()
        }
    }

    private func handleCameraSettings(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let settings = try? JSONDecoder().decode(CameraSettingsRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid camera settings request")
        }

        guard let service = cameraControlService else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No camera control service")
        }

        do {
            try await service.updateCameraSettings(settings)
            return HTTPResponse.success(message: "Camera settings updated")
        } catch {
            return HTTPResponse.error(status: 500, code: "CAMERA_UPDATE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleMeasureWhiteBalance() async -> HTTPResponse {
        guard let service = cameraControlService else {
            print("⚠️ No camera control service available")
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No camera control service")
        }

        do {
            let (sceneCCT_K, tint) = try await service.measureWhiteBalance()
            print("✅ White balance measured: SceneCCT_K = \(sceneCCT_K)K (physical), tint = \(String(format: "%.1f", tint))")

            let result = WhiteBalanceMeasureResponse(sceneCCT_K: sceneCCT_K, tint: tint)
            return HTTPResponse.json(result)
        } catch {
            print("❌ White balance measure failed: \(error.localizedDescription)")
            return HTTPResponse.error(status: 500, code: "MEASURE_FAILED", message: error.localizedDescription)
        }
    }

    private func handleGetTorchLevel() async -> HTTPResponse {
        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        let response = await handler.handleGetTorchLevel()
        return HTTPResponse.json(response)
    }

    private func handlePutTorchLevel(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(TorchLevelUpdateRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid torch level request")
        }

        guard let handler = requestHandler else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No request handler")
        }

        do {
            let response = try await handler.handleUpdateTorchLevel(request)
            print("✅ Torch level updated to: \(response.currentLevel)")
            return HTTPResponse.json(response)
        } catch {
            print("❌ Torch level update failed: \(error.localizedDescription)")
            return HTTPResponse.error(status: 500, code: "TORCH_UPDATE_FAILED", message: error.localizedDescription)
        }
    }
}
