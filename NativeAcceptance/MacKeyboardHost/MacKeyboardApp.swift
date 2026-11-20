import AppKit
import Foundation
import Security
import SuwopShell
import SwiftUI

@main @MainActor struct MacKeyboardApp: App {
    @StateObject private var fixture = MacKeyboardFixture()
    private let sceneID = "generated-mac-keyboard"

    var body: some Scene {
        Window("Suwop Keyboard Acceptance", id: sceneID) {
            VStack(spacing: 0) {
                MacKeyboardStatus(text: "\(Bundle.main.bundleIdentifier ?? "unknown"): \(fixture.status)")
                    .fixedSize()
                if let model = fixture.model {
                    GalleryView(model: model, sceneID: sceneID)
                        .environment(\.protectionSceneID, sceneID)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 760, minHeight: 640)
            .task { await fixture.start() }
        }
        .defaultSize(width: 880, height: 680)
    }
}

/// A read-only text field keeps the fixture value separate from the tab's static accessibility text.
private struct MacKeyboardStatus: NSViewRepresentable {
    private final class StatusField: NSTextField {
        override var acceptsFirstResponder: Bool {
            false
        }
    }

    let text: String

    func makeNSView(context _: Context) -> NSTextField {
        let field = StatusField(frame: .zero)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.isEnabled = false
        field.setAccessibilityElement(true)
        field.setAccessibilityRole(.textField)
        field.setAccessibilityIdentifier("macKeyboardFixtureStatus")
        return field
    }

    func updateNSView(_ field: NSTextField, context _: Context) {
        field.stringValue = text
        field.setAccessibilityValue(text)
    }
}

/// The production model and views consume a real Rust catalog. Every effect and
/// image is supplied here, without constructing AppleShell or a native library.
@MainActor private final class MacKeyboardFixture: ObservableObject {
    private static let scope = "generated-mac-keyboard"
    private static let photos = [
        makePhoto(id: "summer", name: "summer.jpg", seconds: 1_751_414_400, digestDigit: "1"),
        makePhoto(id: "shore", name: "sumer-shore.jpg", seconds: 1_751_328_000, digestDigit: "2"),
    ]
    @Published private(set) var model: LibraryModel?
    @Published private(set) var status = "loading"
    private var journal: JSONValue = .null
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        guard Self.isSandboxedFixture() else {
            status = "failed: fixture sandbox required"
            return
        }
        do {
            let library = try LibraryModel(
                runtime: RustRuntime(),
                thumbnailEffect: { [weak self] key, _ in
                    guard let self else { throw CancellationError() }
                    guard Self.photos.contains(where: { $0.key == key }) else {
                        throw reject("unrecognized image key")
                    }
                    return Self.draw(color: key.assetID == "summer" ? .systemOrange : .systemTeal)
                },
                executeEffect: { [weak self] operation in
                    guard let self else { throw CancellationError() }
                    return try execute(operation)
                }
            )
            library.send(["type": .string("initialize"), "scope": .string(Self.scope)])
            await library.untilSettled()
            library.refresh()
            await library.untilSettled()
            guard status == "loading" else { return }
            guard library.errorMessage == nil, library.publishedAssetKeys == Set(Self.photos.map(\.key)) else {
                throw SuwopError("Fixture did not publish its generated catalog")
            }
            model = library
            status = "ready"
        } catch {
            status = "failed: \(error.localizedDescription)"
        }
    }

    private static func isSandboxedFixture() -> Bool {
        let sandbox = "com.apple.security.app-sandbox"
        let entitlements = [
            sandbox,
            "com.apple.security.temporary-exception.files.absolute-path.read-only",
            "com.apple.security.temporary-exception.files.absolute-path.read-write",
            "com.apple.security.temporary-exception.mach-lookup.global-name",
            "com.apple.security.personal-information.photos-library",
            "com.apple.security.network.client",
            "com.apple.security.network.server",
            "keychain-access-groups",
        ]
        guard Bundle.main.bundleIdentifier == "jp.rabe1028.suwop.mac-keyboard.fixture",
              let task = SecTaskCreateFromSelf(nil),
              let active = SecTaskCopyValuesForEntitlements(task, entitlements as CFArray, nil) as? [String: Bool]
        else { return false }
        return active == [sandbox: true]
    }

    private func execute(_ operation: ShellOperation) throws -> JSONValue {
        switch operation.type {
        case "readState": return journal
        case "persist":
            journal = operation.data ?? .null
            return .null
        case "appleScan":
            guard let data = operation.data,
                  case let .string(scope) = data["scope"], scope == Self.scope,
                  case .bool(false) = data["permission"]
            else { throw reject("appleScan outside the fixture") }
            var snapshot = LibrarySnapshot(provider: .apple, scope: scope, assets: Self.photos, access: .full)
            if let limit = try data["previewLimit"].decode(Int?.self) {
                guard limit > 0 else { throw reject("invalid appleScan preview limit") }
                snapshot.assets = Array(snapshot.assets.prefix(limit))
                snapshot.access = .limited
                return try .object(["preview": .from(snapshot)])
            }
            return try .from(snapshot)
        default: throw reject(operation.type)
        }
    }

    private func reject(_ operation: String) -> SuwopError {
        status = "blocked: \(operation)"
        return SuwopError(status)
    }

    private static func makePhoto(id: String, name: String, seconds: TimeInterval, digestDigit: String) -> StoredAsset {
        StoredAsset(
            appleVisibility: .visible,
            key: AssetKey(provider: .apple, scope: scope, assetID: id),
            name: name,
            capturedAt: Date(timeIntervalSince1970: seconds),
            revision: "generated-1",
            resources: [
                PhotoResource(
                    id: id,
                    name: name,
                    role: .image,
                    sha1: String(repeating: digestDigit, count: 40),
                    bytes: 2500
                ),
            ],
            inventoryComplete: true
        )
    }

    private static func draw(color: NSColor) -> NSImage {
        let image = NSImage(size: CGSize(width: 240, height: 240))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 240, height: 240)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: 48, y: 104, width: 52, height: 52)).fill()
        image.unlockFocus()
        return image
    }
}
