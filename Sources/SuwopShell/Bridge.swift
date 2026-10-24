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

/// Rust rejected the input budget before consuming the pending effect ID.
public struct BridgeInputRejected: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? {
        message
    }
}

#if DEBUG
    public enum JSONDecodeDiagnostic {
        @TaskLocal public static var failure: (@Sendable (Data, String, any Error, [String]) -> Void)?
    }
#endif

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
        let data = try Wire.encoder().encode(self)
        do {
            return try Wire.decoder().decode(type, from: data)
        } catch {
            #if DEBUG
                JSONDecodeDiagnostic.failure?(data, String(reflecting: type), error, Thread.callStackSymbols)
            #endif
            throw error
        }
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

struct DecodedMeasurement<Value> {
    let value: Value
    let start: TimeInterval
    let decodeStart: TimeInterval
    let end: TimeInterval
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

    /// Decode large views directly instead of materializing and re-encoding JSONValue.
    public func callDecoded<Value: Decodable>(_ action: UInt32, as type: Value.Type) throws -> Value {
        try callDecodedMeasured(action, as: type).value
    }

    /// Separate synchronous Rust/FFI work from Swift JSON decoding using one monotonic clock.
    func callDecodedMeasured<Value: Decodable>(
        _ action: UInt32, as type: Value.Type
    ) throws -> DecodedMeasurement<Value> {
        try callDecodedMeasured(action, as: type) { $0 }
    }

    /// `transform` runs inside the measured decode window, on the caller's actor.
    func callDecodedMeasured<Payload: Decodable, Value>(
        _ action: UInt32, as type: Payload.Type, transform: (Payload) throws -> Value
    ) throws -> DecodedMeasurement<Value> {
        let start = ProcessInfo.processInfo.systemUptime
        let output = try Self.invokeData(handle: handle, action: action, input: .null)
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let payload = try Self.decodeEnvelope(Payload.self, from: output, action: action)
        let value = try transform(payload)
        return DecodedMeasurement(
            value: value,
            start: start,
            decodeStart: decodeStart,
            end: ProcessInfo.processInfo.systemUptime
        )
    }

    public static func utility(_ action: UInt32, input: JSONValue) throws -> JSONValue {
        try invoke(handle: 0, action: action, input: input)
    }

    private static func invoke(handle: UInt64, action: UInt32, input: JSONValue) throws -> JSONValue {
        let output = try invokeData(handle: handle, action: action, input: input)
        return try decodeEnvelope(JSONValue.self, from: output, action: action)
    }

    private static func decodeEnvelope<Value: Decodable>(
        _ type: Value.Type, from output: Data, action: UInt32
    ) throws -> Value {
        do {
            return try Wire.decoder().decode(BridgeEnvelope<Value>.self, from: output).value
        } catch let error as DecodingError {
            #if DEBUG
                NSLog("%@", decodeFailureReport(Value.self, from: output, action: action, error: error))
            #endif
            throw error
        }
    }

    #if DEBUG
        /// Intermittent CI failures reported impossible paths (Double expected at
        /// `effect.Io.type`). Records whether Rust's bytes were valid JSON and whether a
        /// Swift-owned copy decodes, to tell bad output from unstable reading.
        static func decodeFailureReport<Value: Decodable>(
            _ type: Value.Type, from output: Data, action: UInt32, error: any Error
        ) -> String {
            let copy = Data(output)
            let valid = (try? JSONSerialization.jsonObject(with: copy)) != nil
            let retried = (try? Wire.decoder().decode(BridgeEnvelope<Value>.self, from: copy)) != nil
            let excerpt = String(bytes: copy.prefix(2048), encoding: .utf8) ?? "<not UTF-8>"
            return "SUWOP_BRIDGE_DECODE_FAILURE action=\(action) bytes=\(copy.count) "
                + "validJSON=\(valid) copiedRetryDecodes=\(retried) error=\(error) payload=\(excerpt)"
        }
    #endif

    private static func invokeData(handle: UInt64, action: UInt32, input: JSONValue) throws -> Data {
        let data = try Wire.encoder().encode(input)
        guard let text = String(data: data, encoding: .utf8) else { throw SuwopError("JSON を生成できません。") }
        let pointer = text.withCString { suwop_call(handle, action, $0) }
        guard let pointer else { throw SuwopError("Rust コアから応答がありません。") }
        // Rust returns a NUL-terminated CString with no interior NUL. The Data adopts
        // that allocation without copying and returns it to Rust exactly once, when the
        // last reference is released; JSONDecoder still validates UTF-8 itself.
        let count = strlen(pointer)
        guard count > 0 else {
            suwop_free(pointer)
            throw SuwopError("Rust コアから応答がありません。")
        }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(pointer),
            count: count,
            deallocator: .custom { bytes, _ in
                suwop_free(bytes.assumingMemoryBound(to: CChar.self))
            }
        )
    }
}

private struct BridgeEnvelope<Value: Decodable>: Decodable {
    let value: Value
    private enum CodingKeys: String, CodingKey { case value, error, inputRejected }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try container.decodeIfPresent(String.self, forKey: .error) {
            if try container.decodeIfPresent(Bool.self, forKey: .inputRejected) == true {
                throw BridgeInputRejected(message: error)
            }
            throw SuwopError(error)
        }
        value = try container.decode(Value.self, forKey: .value)
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
