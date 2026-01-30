//
//  StatusProvider.swift
//  AvoCam
//
//  Protocol for status provider abstraction
//

import Foundation

protocol StatusProvider: AnyObject {
    func getStatus() async -> StatusResponse
}
