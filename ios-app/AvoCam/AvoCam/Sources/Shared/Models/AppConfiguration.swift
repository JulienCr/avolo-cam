//
//  AppConfiguration.swift
//  AvoCam
//
//  Centralized application configuration management
//

import Foundation

/// Centralized configuration for AVOLO-CAM app
struct AppConfiguration {
    // MARK: - Properties

    /// Camera alias for NDI stream naming (e.g., "AVOLO-CAM-A3")
    let cameraAlias: String

    /// Bearer token for API authentication
    let bearerToken: String

    /// Whether authentication is required for API endpoints
    var isAuthenticationEnabled: Bool

    /// HTTP server port (default: 8888)
    let serverPort: Int

    // MARK: - Constants

    /// Default server port for HTTP/WebSocket API
    static let defaultServerPort = 8888

    // MARK: - Loading & Saving

    /// Load configuration from UserDefaults, generating defaults if needed
    /// - Returns: Fully populated configuration
    static func load() -> AppConfiguration {
        let defaults = UserDefaults.standard

        // Load or generate camera alias
        let alias: String
        if let savedAlias = defaults.cameraAlias {
            alias = savedAlias
        } else {
            alias = generateDefaultAlias()
            defaults.cameraAlias = alias
        }

        // Load or generate bearer token
        let token: String
        if let savedToken = defaults.bearerToken {
            token = savedToken
        } else {
            token = generateToken()
            defaults.bearerToken = token
        }

        // Load authentication setting (defaults to false)
        let authEnabled = defaults.isAuthenticationEnabled

        let config = AppConfiguration(
            cameraAlias: alias,
            bearerToken: token,
            isAuthenticationEnabled: authEnabled,
            serverPort: defaultServerPort
        )

        Log.config.info("Configuration loaded: \(alias), auth: \(authEnabled ? "enabled" : "disabled")")
        return config
    }

    /// Save configuration to UserDefaults
    func save() {
        let defaults = UserDefaults.standard
        defaults.cameraAlias = cameraAlias
        defaults.bearerToken = bearerToken
        defaults.isAuthenticationEnabled = isAuthenticationEnabled
        Log.config.info("Configuration saved: \(cameraAlias), auth: \(isAuthenticationEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Generation Helpers

    /// Generate default camera alias in format "AVOLO-CAM-XX" where XX is random hex
    /// - Returns: Generated alias string
    static func generateDefaultAlias() -> String {
        let randomHex = String(format: "%02X", Int.random(in: 0...255))
        return "AVOLO-CAM-\(randomHex)"
    }

    /// Generate cryptographically random bearer token (UUID without dashes)
    /// - Returns: Generated token string
    static func generateToken() -> String {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - Mutation

    /// Update camera alias and save
    /// - Parameter newAlias: New camera alias
    /// - Returns: Updated configuration
    func withAlias(_ newAlias: String) -> AppConfiguration {
        var mutable = AppConfiguration(
            cameraAlias: newAlias,
            bearerToken: bearerToken,
            isAuthenticationEnabled: isAuthenticationEnabled,
            serverPort: serverPort
        )
        mutable.save()
        return mutable
    }

    /// Toggle authentication and save
    /// - Returns: Updated configuration
    func withAuthenticationToggled() -> AppConfiguration {
        var mutable = AppConfiguration(
            cameraAlias: cameraAlias,
            bearerToken: bearerToken,
            isAuthenticationEnabled: !isAuthenticationEnabled,
            serverPort: serverPort
        )
        mutable.save()
        return mutable
    }
}
