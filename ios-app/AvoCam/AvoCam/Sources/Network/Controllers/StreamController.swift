//
//  StreamController.swift
//  AvoCam
//
//  HTTP controller for stream control endpoints
//

import Foundation

/// Controller for stream start/stop endpoints
final class StreamController: APIController {
    private weak var streamingService: StreamingService?

    init(streamingService: StreamingService) {
        self.streamingService = streamingService
    }

    func registerRoutes(router: HTTPRouter) {
        router.post("/api/v1/stream/start") { [weak self] _, _, _, body in
            await self?.handleStreamStart(body: body) ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/stream/stop") { [weak self] _, _, _, _ in
            await self?.handleStreamStop() ?? HTTPResponse.internalError()
        }

        router.post("/api/v1/encoder/force_keyframe") { [weak self] _, _, _, _ in
            await self?.handleForceKeyframe() ?? HTTPResponse.internalError()
        }
    }

    private func handleStreamStart(body: Data?) async -> HTTPResponse {
        guard let body = body,
              let request = try? JSONDecoder().decode(StreamStartRequest.self, from: body) else {
            return HTTPResponse.badRequest(code: "INVALID_REQUEST", message: "Invalid stream start request")
        }

        guard let service = streamingService else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No streaming service")
        }

        do {
            try await service.startStreaming(request: request)
            print("✅ Stream started: \(request.resolution)@\(request.framerate)fps")
            return HTTPResponse.success(message: "Stream started")
        } catch {
            print("❌ Stream start failed: \(error.localizedDescription)")
            return HTTPResponse.error(status: 500, code: "STREAM_START_FAILED", message: error.localizedDescription)
        }
    }

    private func handleStreamStop() async -> HTTPResponse {
        guard let service = streamingService else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No streaming service")
        }

        await service.stopStreaming()
        print("✅ Stream stopped")
        return HTTPResponse.success(message: "Stream stopped")
    }

    private func handleForceKeyframe() async -> HTTPResponse {
        guard let service = streamingService else {
            return HTTPResponse.internalError(code: "INTERNAL_ERROR", message: "No streaming service")
        }

        // Note: This requires adding forceKeyframe to StreamingService protocol
        // For now, return success acknowledgment
        print("🔑 Force keyframe requested")
        return HTTPResponse.success(message: "Keyframe requested")
    }
}
