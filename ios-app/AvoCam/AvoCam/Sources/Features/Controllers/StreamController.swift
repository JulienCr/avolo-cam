//
//  StreamController.swift
//  AvoCam
//
//  Handles stream control endpoints (start/stop/keyframe)
//

import Foundation

// MARK: - Stream Controller

class StreamController {
    // MARK: - Properties

    private weak var handler: NetworkRequestHandler?

    // MARK: - Initialization

    init(handler: NetworkRequestHandler?) {
        self.handler = handler
    }

    // MARK: - Stream Control Endpoints

    /// POST /api/v1/stream/start
    func startStream(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        let startRequest = try request.decodeBody(
            StreamStartRequest.self,
            using: JSONCodec.shared.decoder
        )

        do {
            try await handler.handleStreamStart(startRequest)
            print("✅ Stream started: \(startRequest.resolution)@\(startRequest.framerate)fps")
            return SuccessResponse(message: "Stream started")
        } catch {
            throw NetworkError.streamStartFailed(error.localizedDescription)
        }
    }

    /// POST /api/v1/stream/stop
    func stopStream(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        guard let handler = handler else {
            throw NetworkError.handlerNotAvailable
        }

        do {
            try await handler.handleStreamStop()
            print("✅ Stream stopped")
            return SuccessResponse(message: "Stream stopped")
        } catch {
            throw NetworkError.streamStopFailed(error.localizedDescription)
        }
    }

    /// POST /api/v1/encoder/force_keyframe
    func forceKeyframe(request: HTTPRequest) async throws -> HTTPResponseEncodable {
        // TODO: Add handleForceKeyframe to NetworkRequestHandler protocol
        throw NetworkError.notImplemented("Force keyframe not yet implemented")
    }
}
