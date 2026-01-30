//
//  UserDefaults+Keys.swift
//  AvoCam
//
//  Type-safe UserDefaults keys and accessors
//

import Foundation

extension UserDefaults {
    /// Type-safe keys for UserDefaults storage
    enum Key: String {
        case cameraAlias = "camera_alias"
        case bearerToken = "bearer_token"
        case authenticationEnabled = "authentication_enabled"
        case cameraSettings = "camera_settings"
        case videoSettings = "video_settings"
    }

    // MARK: - String Accessors

    /// Camera alias for NDI stream identification
    var cameraAlias: String? {
        get { string(forKey: Key.cameraAlias.rawValue) }
        set { set(newValue, forKey: Key.cameraAlias.rawValue) }
    }

    /// Bearer token for API authentication
    var bearerToken: String? {
        get { string(forKey: Key.bearerToken.rawValue) }
        set { set(newValue, forKey: Key.bearerToken.rawValue) }
    }

    // MARK: - Boolean Accessors

    /// Whether authentication is enabled for API endpoints
    var isAuthenticationEnabled: Bool {
        get { bool(forKey: Key.authenticationEnabled.rawValue) }
        set { set(newValue, forKey: Key.authenticationEnabled.rawValue) }
    }

    // MARK: - Data Accessors

    /// Encoded camera settings (JSON)
    var cameraSettingsData: Data? {
        get { data(forKey: Key.cameraSettings.rawValue) }
        set { set(newValue, forKey: Key.cameraSettings.rawValue) }
    }

    /// Encoded video settings (JSON)
    var videoSettingsData: Data? {
        get { data(forKey: Key.videoSettings.rawValue) }
        set { set(newValue, forKey: Key.videoSettings.rawValue) }
    }
}
