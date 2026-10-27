import Foundation
import SuwopShell

@MainActor final class ImportAcceptanceDriver {
    let runtime: RustRuntime
    let shell: AppleShell
    private var allowed: [AssetKey]
    private(set) var created: [AssetKey] = []
    var loseCreationResponse = false

    init(allowed: [AssetKey]) throws {
        runtime = try RustRuntime()
        shell = try AppleShell()
        self.allowed = allowed
    }

    func event(_ type: String, _ payload: [String: JSONValue], allowError: Bool = false) async throws -> ViewModel {
        var event = payload
        event["type"] = .string(type)
        var requests = try await runtime.update(.object(event))
        let context = shell.beginWorkflow()
        var steps = 0
        while !requests.isEmpty {
            steps += 1
            guard steps < 250 else { throw SuwopError("Import fixture effect limit.") }
            let request = requests.removeFirst()
            guard let operation = request.effect["Io"] else { throw SuwopError("Unknown effect.") }
            var value: JSONValue?
            var failure: String?
            do {
                try fence(operation)
                value = try await shell.execute(operation, context: context)
                if operation.type == "appleImportStaged", let value {
                    let keys = try value.decode([AssetKey].self)
                    guard keys.allSatisfy({ !allowed.contains($0) })
                    else { throw SuwopError("Native creation reused source ID.") }
                    created += keys
                    allowed += keys
                    if loseCreationResponse {
                        loseCreationResponse = false
                        throw SuwopError("Intentional lost response after generated PhotoKit create.")
                    }
                }
            } catch { value = nil
                failure = error.localizedDescription
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: failure)
        }
        let view = try await runtime.view()
        guard !view.busy else { throw SuwopError("Import fixture remained busy.") }
        if !allowError, let error = view.error {
            throw SuwopError(error)
        }
        return view
    }

    private func fence(_ operation: ShellOperation) throws {
        if ["appleExport", "appleImportReadback"].contains(operation.type) {
            let keys = try (operation.data ?? .null)["keys"].decode([AssetKey].self)
            guard !keys.isEmpty,
                  keys.allSatisfy(allowed.contains) else { throw SuwopError("Refusing non-fixture export.") }
        }
        let allowedEffects: Set = [
            "readState", "persist", "readStateVersioned", "persistIfCurrent", "appleScan", "appleExport",
            "workspace", "cleanup", "hashFile", "stageImportFiles", "resolveImportResource", "releaseImportStaging",
            "appleImportStaged", "appleImportReadback",
        ]
        guard allowedEffects.contains(operation.type) else {
            throw SuwopError("Refusing non-import effect: \(operation.type)")
        }
    }
}
