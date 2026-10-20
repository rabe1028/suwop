import Foundation

public struct RuntimeSnapshot: Sendable {
    public let revision: UInt64
    public let view: ViewModel
    public var measuredStart: TimeInterval?
    public var measuredDuration: TimeInterval?

    public init(revision: UInt64, view: ViewModel) {
        self.revision = revision
        self.view = view
    }
}

public struct RuntimeProgress: Decodable, Sendable {
    public let version: String
    public let progress: String?
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
        do {
            return try bridge.call(1, input: .object(["id": .number(Double(id)), "response": response]))
                .decode([EffectRequest].self)
        } catch let rejected as BridgeInputRejected {
            // The oversized value never reached the reducer. Complete that exact
            // pending effect with failure so Rust can clear busy and retain its
            // normal uncertainty/cleanup rules. Never repeat the native operation.
            let failure: JSONValue = .object(["value": .null, "error": .string(rejected.message)])
            return try bridge.call(1, input: .object(["id": .number(Double(id)), "response": failure]))
                .decode([EffectRequest].self)
        }
    }

    public func view() throws -> ViewModel {
        try bridge.callDecoded(2, as: ViewModel.self)
    }

    /// Query current Rust authority without serializing every photo for each thumbnail.
    public func ordinaryContentRevision(
        keys: [AssetKey],
        expectedRevision: String?,
        requiresPublishedKey: Bool
    ) throws -> String {
        let projection = try bridge.call(16, input: .from(keys))
        let allowed = try projection["keys"].decode([AssetKey].self)
        guard let current = projection["revision"].string,
              !keys.isEmpty,
              expectedRevision == nil || expectedRevision == current,
              !requiresPublishedKey || keys.allSatisfy(allowed.contains)
        else { throw CancellationError() }
        return current
    }

    public func progress() throws -> RuntimeProgress {
        try bridge.callDecoded(17, as: RuntimeProgress.self)
    }

    public func snapshot() throws -> RuntimeSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        var result = try RuntimeSnapshot(revision: revision, view: view())
        result.measuredStart = start
        result.measuredDuration = ProcessInfo.processInfo.systemUptime - start
        return result
    }

    /// Publish browser input and its resulting view in one actor turn.
    public func browse(_ options: BrowserOptions) throws -> RuntimeSnapshot {
        try Task.checkCancellation()
        _ = try update(.object(["type": .string("browse"), "options": .from(options)]))
        return try snapshot()
    }

    public func browseAlbumCandidates(_ key: AlbumKey?) throws -> RuntimeSnapshot {
        _ = try update(.object(["type": .string("browseAlbumCandidates"), "key": key.map(JSONValue.from) ?? .null]))
        return try snapshot()
    }

    public func choosePreview(anchor: AssetKey, key: AssetKey) throws -> RuntimeSnapshot {
        try Task.checkCancellation()
        _ = try update(.object(["type": .string("choosePreview"), "anchor": .from(anchor), "key": .from(key)]))
        return try snapshot()
    }
}
