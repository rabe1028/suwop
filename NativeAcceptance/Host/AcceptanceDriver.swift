import Foundation
import SuwopShell
import UIKit

/// Only presentation answers are supplied by the test. Every native effect uses
/// the production adapter; Rust still creates plans, journals and decisions.
@MainActor final class AcceptanceDriver {
    let runtime = try? RustRuntime()
    let shell: AppleShell?
    let keys: [AssetKey]
    var loseNextSaveResponse = false
    var cancelEditor = false
    var cancelTrash = false
    var loseNextTrashResponse = false
    var shareAnswer: (@MainActor (SharePresentation) async throws -> Bool)?
    var beforeEffect: (@MainActor (ShellOperation) throws -> Void)?
    var afterEffect: (@MainActor (ShellOperation, JSONValue) throws -> Void)?
    private(set) var visibilityPersistedBeforeApply = false
    private(set) var savedAdjustment: AppleAdjustment?
    private(set) var effects: [String] = []
    private(set) var queuedEffects: [String] = []

    init(keys: [AssetKey], root: URL? = nil) {
        self.keys = keys
        shell = try? AppleShell(root: root)
        if let runtime {
            shell?.ordinaryContent.configure(runtime: runtime)
        }
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
            queuedEffects = requests.compactMap { $0.effect["Io"]?.type }
            effects.append(operation.type)
            var value: JSONValue?
            let failure: String?
            do {
                try fence(operation)
                try beforeEffect?(operation)
                value = try await execute(operation, shell: shell, context: context)
                if let value {
                    try afterEffect?(operation, value)
                }
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
        case "shareFiles":
            return try await executeShare(operation, shell: shell, context: context)
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
        case "confirmAppleVisibility", "appleVisibilityApply":
            return try await executeVisibility(operation, shell: shell, context: context)
        case "confirmAppleTrash": return .bool(context.permits() && !cancelTrash)
        case "appleTrashApply":
            return try await executeTrash(operation, shell: shell, context: context)
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

    private func executeShare(
        _ operation: ShellOperation, shell: AppleShell, context: ContentPresentationContext
    ) async throws -> JSONValue {
        guard let shareAnswer else { return try await shell.execute(operation, context: context) }
        let presentation = try (operation.data ?? .null).decode(SharePresentation.self)
        try context.requireCurrent(sourceKeys: presentation.sourceKeys ?? [])
        _ = try await shell.ordinaryContent.validate(keys: presentation.sourceKeys ?? [], context: context)
        return try await .bool(shareAnswer(presentation))
    }

    private func executeTrash(
        _ operation: ShellOperation, shell: AppleShell, context: ContentPresentationContext
    ) async throws -> JSONValue {
        let result = try await shell.execute(operation, context: context)
        if loseNextTrashResponse {
            loseNextTrashResponse = false
            throw SuwopError("Intentional lost response after real PhotoKit deletion.")
        }
        return result
    }

    private func executeVisibility(
        _ operation: ShellOperation, shell: AppleShell, context: ContentPresentationContext
    ) async throws -> JSONValue {
        if operation.type == "confirmAppleVisibility" {
            return .bool(context.permits())
        }
        let request = try (operation.data ?? .null)["request"].decode(AppleVisibilityApply.self)
        let read = try JSONValue.object(["type": .string("readState")]).decode(ShellOperation.self)
        let canonical = try await shell.execute(read, context: context).decode(SavedLibrary.self)
        guard canonical.appleVisibilityOperations.contains(where: {
            $0.id == request.id && $0.outcome == .unknown && $0.targets.map(\.key) == request.targets.map(\.key)
        }) else { throw SuwopError("Native visibility write preceded durable Rust Unknown intent.") }
        visibilityPersistedBeforeApply = true
        return try await shell.execute(operation, context: context)
    }

    private func fence(_ operation: ShellOperation) throws {
        let data = operation.data ?? .null
        let assetEffects = [
            "appleEditSave",
            "appleRevert",
            "appleEditOpen",
            "appleEditInspect",
            "appleReversionInspect",
            "appleCurrentMedia",
            "appleCurrentImage",
        ]
        if assetEffects.contains(operation.type) {
            let asset = try data["asset"].decode(StoredAsset.self)
            guard keys.contains(asset.key) else { throw SuwopError("Refusing a non-fixture photo.") }
        }
        try visibilityFence(operation)
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
        try shareFence(operation)
        guard !["appleTrash", "appleImport", "appleFavorite", "appleMetadata", "http"].contains(operation.type) else {
            throw SuwopError("Unrequested native mutation / network operation.")
        }
    }

    private func shareFence(_ operation: ShellOperation) throws {
        guard operation.type == "shareFiles" else { return }
        let requested = try (operation.data ?? .null).decode(SharePresentation.self).sourceKeys ?? []
        guard !requested.isEmpty, requested.allSatisfy(keys.contains) else {
            throw SuwopError("Refusing non-fixture sharing.")
        }
    }

    private func visibilityFence(_ operation: ShellOperation) throws {
        let data = operation.data ?? .null
        if operation.type == "appleVisibilityApply" {
            let request = try data["request"].decode(AppleVisibilityApply.self)
            guard !request.targets.isEmpty, request.targets.allSatisfy({ keys.contains($0.key) }) else {
                throw SuwopError("Refusing a non-fixture visibility mutation.")
            }
        }
        if operation.type == "appleVisibilityInspect" {
            let requested = try data["keys"].decode([AssetKey].self)
            guard requested.allSatisfy(keys.contains)
            else { throw SuwopError("Refusing a non-fixture visibility inspection.") }
        }
    }
}
