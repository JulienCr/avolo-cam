//
//  StreamingService.swift
//  AvoCam
//
//  Protocol for streaming service abstraction
//

import Foundation

protocol StreamingService: AnyObject {
    var isCurrentlyStreaming: Bool { get async }
    func startStreaming(request: StreamStartRequest) async throws
    func stopStreaming() async
}
