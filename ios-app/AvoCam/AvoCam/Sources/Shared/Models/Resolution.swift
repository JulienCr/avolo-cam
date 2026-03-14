//
//  Resolution.swift
//  AvoCam
//
//  Shared resolution type for "WIDTHxHEIGHT" string parsing
//

import Foundation

/// Parsed video resolution from a "WIDTHxHEIGHT" format string (e.g. "1920x1080").
///
/// Replaces three duplicate resolution-parsing implementations across
/// `CaptureManager`, `StreamingCoordinator`, and `SRTConfiguration`.
struct Resolution: Sendable, Equatable {
    /// Width in pixels.
    let width: Int

    /// Height in pixels.
    let height: Int

    /// The default resolution used as a fallback (1920x1080).
    static let defaultResolution = Resolution(width: 1920, height: 1080)

    /// Width as `Int32`, for use with AVFoundation/CoreMedia APIs.
    var width32: Int32 { Int32(width) }

    /// Height as `Int32`, for use with AVFoundation/CoreMedia APIs.
    var height32: Int32 { Int32(height) }

    /// Parse a resolution string in "WIDTHxHEIGHT" format.
    ///
    /// - Parameter string: A string like "1920x1080" or "3840x2160".
    /// - Returns: A `Resolution` if parsing succeeds, or `nil` if the format is invalid.
    init?(parsing string: String) {
        let components = string.split(separator: "x")
        guard components.count == 2,
              let w = Int(components[0]),
              let h = Int(components[1]) else {
            return nil
        }
        self.width = w
        self.height = h
    }

    /// Direct initializer with explicit width and height.
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Parse a resolution string, returning ``defaultResolution`` (1920x1080) on failure.
    ///
    /// Use this when a fallback is acceptable (e.g. streaming configuration).
    /// For strict validation (e.g. capture format selection), use ``init(parsing:)`` instead.
    ///
    /// - Parameter string: A string like "1920x1080".
    /// - Returns: The parsed resolution, or 1920x1080 if parsing fails.
    static func parseWithDefault(_ string: String) -> Resolution {
        return Resolution(parsing: string) ?? .defaultResolution
    }
}
