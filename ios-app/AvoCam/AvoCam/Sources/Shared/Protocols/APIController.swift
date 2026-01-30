//
//  APIController.swift
//  AvoCam
//
//  Protocol for API controller abstraction
//

import Foundation

protocol APIController {
    func registerRoutes(router: HTTPRouter)
}
