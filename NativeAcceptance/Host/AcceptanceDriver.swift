import SuwopShell
import UIKit

/// Only presentation answers are supplied by the test. Every native effect uses
/// the production adapter; Rust still creates plans, journals and decisions.
@MainActor final class AcceptanceDriver {
    let runtime = try? RustRuntime()
    let shell = try? AppleShell()
    let keys: [AssetKey]
    var loseNextSaveResponse = false
    var cancelEditor = false
    var cancelTrash = false
    var loseNextTrashResponse = false
    private(set) var savedAdjustment: AppleAdjustment?
    private(set) var effects: [String] = []

    init(keys: [AssetKey]) {
        self.keys = keys
    }

    func event(_ type: String, _ data: [String: JSONValue] = [:], allowError: Bool = false) async throws -> ViewModel {
        guard let runtime, let shell else { throw SuwopError("Cannot create production Rust runtime / shell.") }
        var event = data
        event["type"] = .string(type)
        let context = shell.beginWorkflow()
        var requests = try await runtime.update(.object(event))
        var steps = 0
        while !requests.isEmpty {
            steps += 1
            guard steps < 200 else { throw SuwopError("Effect sequence did not finish.") }
            let request = requests.removeFirst()
            guard let operation = request.effect["Io"] else { throw SuwopError("Unknown effect.") }
            effects.append(operation.type)
            let value: JSONValue?
            let failure: String?
            do {
                try fence(operation)
                value = try await execute(operation, shell: shell, context: context)
                failure = nil
            } catch {
                value = nil
                failure = error.localizedDescription
            }
            requests += try await runtime.resolve(id: request.id, value: value, error: failure)
        }
        let view = try await runtime.view()
        guard !view.busy else { throw SuwopError("Rust remained busy.") }
        if !allowError, let error = view.error {
            throw SuwopError(error)
        }
        return view
    }

    private func execute(
        _ operation: ShellOperation, shell: AppleShell, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let data = operation.data ?? .null
        switch operation.type {
        case "editImage":
            try context.requireCurrent(sourceKeys: [data["key"].decode(AssetKey.self)])
            if cancelEditor {
                return .null
            }
            let presentation = try data["presentation"].decode(ImageEditPresentation.self)
            let size = presentation.draft.dimensions
            let cropped = try CoreBridge.utility(8, input: .from(EditDraftRequest(
                command: EditCommand(
                    crop: PixelCrop(height: size.height / 2, width: size.width / 2, x: 10, y: 10),
                    kind: .crop
                ),
                draft: presentation.draft
            ))).decode(ImageEditState.self)
            let edited = try CoreBridge.utility(8, input: .from(EditDraftRequest(
                command: EditCommand(
                    color: ColorAdjustments(
                        brightness: 10,
                        contrast: 15,
                        exposure: -50,
                        filter: .sepia,
                        saturation: -25
                    ),
                    kind: .setColor
                ), draft: cropped.draft
            ))).decode(ImageEditState.self)
            return try .from(edited.draft)
        case "confirmAppleTrash": return .bool(context.permits() && !cancelTrash)
        case "appleTrashApply":
            let result = try await shell.execute(operation, context: context)
            if loseNextTrashResponse {
                loseNextTrashResponse = false
                throw SuwopError("Intentional lost response after real PhotoKit deletion.")
            }
            return result
        case "confirmPasteEdits", "confirmReversion": return .bool(context.permits())
        case "appleEditSave":
            let result = try await shell.execute(operation, context: context)
            savedAdjustment = try result.decode(AppleEditResult.self).adjustment
            if loseNextSaveResponse {
                loseNextSaveResponse = false
                throw SuwopError("Intentional lost response after real PhotoKit save.")
            }
            return result
        default: return try await shell.execute(operation, context: context)
        }
    }

    private func fence(_ operation: ShellOperation) throws {
        let data = operation.data ?? .null
        let assetEffects = [
            "appleEditSave",
            "appleRevert",
            "appleEditOpen",
            "appleEditInspect",
            "appleReversionInspect",
        ]
        if assetEffects.contains(operation.type) {
            let asset = try data["asset"].decode(StoredAsset.self)
            guard keys.contains(asset.key) else { throw SuwopError("Refusing a non-fixture photo.") }
        }
        if operation.type == "appleTrashApply" {
            let requested = try data["assets"].decode([StoredAsset].self).map(\.key)
            guard !requested.isEmpty,
                  requested.allSatisfy(keys.contains) else { throw SuwopError("Refusing a non-fixture deletion.") }
        }
        if operation.type == "appleTrashInspect" {
            let requested = try data["keys"].decode([AssetKey].self)
            guard requested.allSatisfy(keys.contains) else { throw SuwopError("Refusing a non-fixture inspection.") }
        }
        if operation.type == "appleExport" {
            let requested = try data["keys"].decode([AssetKey].self)
            guard requested.allSatisfy(keys.contains) else { throw SuwopError("Refusing a non-fixture export.") }
        }
        guard !["appleTrash", "appleImport", "appleFavorite", "appleMetadata", "http"].contains(operation.type) else {
            throw SuwopError("Unrequested native mutation / network operation.")
        }
    }
}
