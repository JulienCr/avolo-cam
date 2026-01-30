//
//  StatusController.swift
//  AvoCam
//
//  HTTP controller for status and capabilities endpoints
//

import Foundation

/// Controller for status and capabilities endpoints
final class StatusController: APIController {
    private weak var statusProvider: StatusProvider?
    private weak var cameraControlService: CameraControlService?

    init(statusProvider: StatusProvider, cameraControlService: CameraControlService) {
        self.statusProvider = statusProvider
        self.cameraControlService = cameraControlService
    }

    func registerRoutes(router: HTTPRouter) {
        router.get("/api/v1/status") { [weak self] _, _, _, _ in
            await self?.handleGetStatus() ?? HTTPResponse.internalError()
        }

        router.get("/api/v1/capabilities") { [weak self] _, _, _, _ in
            await self?.handleGetCapabilities() ?? HTTPResponse.internalError()
        }
    }

    private func handleGetStatus() async -> HTTPResponse {
        guard let provider = statusProvider else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No status provider")
        }

        let status = await provider.getStatus()
        return HTTPResponse.json(status)
    }

    private func handleGetCapabilities() async -> HTTPResponse {
        guard let service = cameraControlService else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No camera control service")
        }

        let capabilities = await service.getCapabilities()
        return HTTPResponse.json(capabilities)
    }
}
