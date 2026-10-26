import Foundation
import SuwopShell

extension AppleShell {
    func requiredString(_ data: JSONValue, _ key: String) throws -> String {
        guard let value = data[key].string else { throw SuwopError("入出力要求に \(key) がありません。") }
        return value
    }

    func stateEffect(_ type: String, data: JSONValue) async throws -> JSONValue {
        if type == "readState" {
            return try await localStore.read()
        }
        if type == "readStateVersioned" {
            return try await localStore.readVersioned()
        }
        if type == "persistIfCurrent" {
            let written = try await localStore.persistIfCurrent(
                revision: requiredString(data, "revision"),
                state: data["state"]
            )
            if written {
                catalogChanged?()
            }
            return .bool(written)
        }
        try await localStore.persist(data)
        catalogChanged?()
        return .null
    }
}
