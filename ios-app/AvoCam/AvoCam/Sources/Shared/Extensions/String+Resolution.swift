//
//  String+Resolution.swift
//  AvoCam
//
//  Resolution string parsing extension
//

import Foundation

extension String {
    nonisolated func parseResolution() -> (width: Int, height: Int)? {
        let parts = self.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        return (width, height)
    }
}
