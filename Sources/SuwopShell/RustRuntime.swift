import Foundation

public struct RuntimeSnapshot: Sendable {
    public let revision: UInt64
    public let view: ViewModel
}

public actor RustRuntime {
    private let bridge: CoreBridge
    private var revision: UInt64 = 0
    public init() throws {
        bridge = try CoreBridge()
    }

    public func update(_ event: JSONValue) throws -> [EffectRequest] {
        defer { revision &+= 1 }
        return try bridge.call(0, input: event).decode([EffectRequest].self)
    }

    public func resolve(id: UInt32, value: JSONValue?, error: String?) throws -> [EffectRequest] {
        defer { revision &+= 1 }
        let response: JSONValue = .object(["value": value ?? .null, "error": error.map(JSONValue.string) ?? .null])
        return try bridge.call(1, input: .object(["id": .number(Double(id)), "response": response]))
            .decode([EffectRequest].self)
    }

    public func view() throws -> ViewModel {
        try bridge.call(2).decode(ViewModel.self)
    }

    public func snapshot() throws -> RuntimeSnapshot {
        try RuntimeSnapshot(revision: revision, view: view())
    }

    /// Publish browser input and its resulting view in one actor turn.
    public func browse(_ options: BrowserOptions) throws -> RuntimeSnapshot {
        try Task.checkCancellation()
        _ = try update(.object(["type": .string("browse"), "options": .from(options)]))
        return try snapshot()
    }

    public func choosePreview(anchor: AssetKey, key: AssetKey) throws -> RuntimeSnapshot {
        try Task.checkCancellation()
        _ = try update(.object(["type": .string("choosePreview"), "anchor": .from(anchor), "key": .from(key)]))
        return try snapshot()
    }
}
