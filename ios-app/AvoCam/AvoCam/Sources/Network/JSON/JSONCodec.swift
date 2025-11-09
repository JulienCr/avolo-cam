//
//  JSONCodec.swift
//  AvoCam
//
//  Centralized JSON encoding/decoding with consistent configuration
//

import Foundation

/// Centralized JSON codec to avoid scattered encoder/decoder instances
struct JSONCodec {
    // MARK: - Shared Instances

    static let shared = JSONCodec()

    let encoder: JSONEncoder
    let decoder: JSONDecoder

    // MARK: - Initialization

    private init() {
        // Configure encoder
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        // Configure decoder
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Encoding

    /// Encode a value to JSON Data
    func encode<T: Encodable>(_ value: T) throws -> Data {
        return try encoder.encode(value)
    }

    /// Encode a value to JSON String
    func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw JSONError.encodingFailed
        }
        return string
    }

    // MARK: - Decoding

    /// Decode JSON Data to a type
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try decoder.decode(type, from: data)
    }

    /// Decode JSON String to a type
    func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw JSONError.decodingFailed
        }
        return try decode(type, from: data)
    }
}

// MARK: - JSON Error

enum JSONError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode JSON"
        case .decodingFailed:
            return "Failed to decode JSON"
        }
    }
}
