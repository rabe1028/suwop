import CSuwop
import Foundation

public struct SuwopError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? {
        message
    }

    public init(_ message: String) {
        self.message = message
    }
}

public enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        if case let .object(value) = self {
            return value[key] ?? .null
        }
        return .null
    }

    public var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public static func from(_ value: some Encodable) throws -> JSONValue {
        try Wire.decoder().decode(JSONValue.self, from: Wire.encoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try Wire.decoder().decode(type, from: Wire.encoder().encode(self))
    }
}

public enum Wire {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Every instance is confined to its actor. Rust additionally serializes calls to its registry.
public final class CoreBridge {
    private let handle: UInt64
    public init() throws {
        handle = suwop_new()
        guard handle != 0 else { throw SuwopError("Rust コアを初期化できません。") }
    }

    deinit { suwop_drop(handle) }
    public func call(_ action: UInt32, input: JSONValue = .null) throws -> JSONValue {
        try Self.invoke(handle: handle, action: action, input: input)
    }

    public static func utility(_ action: UInt32, input: JSONValue) throws -> JSONValue {
        try invoke(handle: 0, action: action, input: input)
    }

    private static func invoke(handle: UInt64, action: UInt32, input: JSONValue) throws -> JSONValue {
        let data = try Wire.encoder().encode(input)
        guard let text = String(data: data, encoding: .utf8) else { throw SuwopError("JSON を生成できません。") }
        let pointer = text.withCString { suwop_call(handle, action, $0) }
        guard let pointer else { throw SuwopError("Rust コアから応答がありません。") }
        defer { suwop_free(pointer) }
        let output = Data(String(cString: pointer).utf8)
        let envelope = try Wire.decoder().decode(JSONValue.self, from: output)
        if let error = envelope["error"].string {
            throw SuwopError(error)
        }
        return envelope["value"]
    }
}

public struct EffectRequest: Decodable, Sendable {
    public var id: UInt32
    public var effect: [String: ShellOperation]
}

public struct ShellOperation: Decodable, Sendable {
    public var type: String
    public var data: JSONValue?
}
