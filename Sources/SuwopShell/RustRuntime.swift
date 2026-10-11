import Foundation

public actor RustRuntime {
    private let bridge: CoreBridge
    public init() throws {
        bridge = try CoreBridge()
    }

    public func update(_ event: JSONValue) throws -> [EffectRequest] {
        try bridge.call(0, input: event).decode([EffectRequest].self)
    }

    public func resolve(id: UInt32, value: JSONValue?, error: String?) throws -> [EffectRequest] {
        let response: JSONValue = .object(["value": value ?? .null, "error": error.map(JSONValue.string) ?? .null])
        return try bridge.call(1, input: .object(["id": .number(Double(id)), "response": response]))
            .decode([EffectRequest].self)
    }

    public func view() throws -> ViewModel {
        try bridge.call(2).decode(ViewModel.self)
    }
}
