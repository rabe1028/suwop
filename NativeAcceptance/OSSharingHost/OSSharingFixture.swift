import Foundation
import SuwopShell
import SwiftUI
#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Complements the real Rust/export native gate with actual OS presentation,
/// receiver and kernel-held workspace evidence. No synthetic completion callback.
@MainActor final class OSSharingFixture: ObservableObject {
    @Published private(set) var state = "ready"
    @Published private(set) var lease = "lease=none"
    @Published private(set) var result = "callbacks=0 cleanup=0 receiver=0"
    @Published private(set) var running = false
    @Published private(set) var nativeWindow = "native-window=not-attached"
    let root: URL
    let receiver: URL
    private let sharing = SystemSharing()
    private let epoch = ContentPresentationEpoch()
    private var workspaces: OperationWorkspaces?
    private var sender: URL?
    private var urls: [URL] = []
    private var callbacks = 0
    private var cleanup = 0
    private var received = false
    private var failure: Error?
    private var expected: [String: String] = [:]
    private var nativeWindowEvents: [String] = []
    #if os(macOS)
        private weak var presentationWindow: NSWindow?
        private var activationRequestSent = "none"
    #endif

    var platform: String {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? "platform=iPad" : "platform=unsupported-iPhone"
        #else
            "platform=macOS"
        #endif
    }

    init() {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OSSharingAcceptance-" + id)
        #if os(iOS)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            receiver = documents.appendingPathComponent("GeneratedReceiver-" + id)
        #else
            receiver = root.appendingPathComponent("GeneratedReceiver-" + id)
        #endif
    }

    func activate() {
        #if os(macOS)
            sharing.localServicesForTesting = { [weak self] items in self?.services(items) ?? [] }
        #endif
    }

    func start() {
        guard !running else { return }
        #if os(macOS)
            requestNativeKeyWindow()
        #endif
        running = true
        state = "preparing"
        Task {
            do { try await present() } catch {
                // SystemSharing throws before presentation or after a terminal SDK error.
                // An unresolved native continuation never enters this cleanup path.
                let presentationError = error.localizedDescription
                do { try cleanupSender() } catch {
                    state = "FAIL: " + presentationError + "; generated workspace cleanup failed"
                    writeReport()
                    running = false
                    return
                }
                state = "FAIL: " + presentationError
                writeReport()
            }
            running = false
        }
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: true)
        #if os(iOS)
            // Only this dedicated test bundle's Documents are exposed to the local Files provider.
            let marker = receiver.deletingLastPathComponent().appendingPathComponent("OSSharing-generated.txt")
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data("Generated OS sharing acceptance fixtures only.\n".utf8).write(
                    to: marker,
                    options: .withoutOverwriting
                )
            }
        #endif
        if workspaces == nil {
            workspaces = try OperationWorkspaces(root: root.appendingPathComponent("sender-workspaces"))
        }
        guard let workspaces,
              let still = Bundle.main.url(forResource: "synthetic-still", withExtension: "jpg"),
              let motion = Bundle.main.url(forResource: "synthetic-motion", withExtension: "mov")
        else { throw SuwopError("Generated sharing resources or workspace unavailable.") }
        let directory = try URL(fileURLWithPath: workspaces.create(id: UUID().uuidString))
        sender = directory
        urls = OSSharingReceiver.names.map { directory.appendingPathComponent($0) }
        for (source, target) in zip([still, motion, still, motion], urls) {
            try FileManager.default.copyItem(at: source, to: target)
        }
        expected = try Dictionary(uniqueKeysWithValues: urls
            .map { try ($0.lastPathComponent, OSSharingReceiver.hash($0)) })
        failure = nil
    }

    private func present() async throws {
        #if os(macOS)
            try await requireNativeKeyWindow()
        #endif
        try prepare()
        guard let sender, workspaces != nil else { throw SuwopError("Missing generated sender lease.") }
        let receiverBefore = try OSSharingReceiver.inventory(receiver)
        state = "waiting"
        lease = "lease=held files=4"
        writeReport()
        let completed = try await sharing.present(SharePresentation(
            files: urls.map { ShareFile(name: $0.lastPathComponent, path: $0.path) },
            sourceKeys: [AssetKey(provider: .apple, scope: "generated-files-only", assetID: "generated-batch")]
        ), context: epoch.beginWorkflow())
        callbacks += 1
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw SuwopError("Sender files were removed before the actual OS completion.")
        }
        if let failure {
            throw failure
        }
        if completed {
            try await OSSharingReceiver.verify(receiver, expected: expected)
            received = true
        } else {
            guard try OSSharingReceiver.inventory(receiver) == receiverBefore else {
                throw SuwopError("Cancelling unexpectedly changed the receiver.")
            }
        }
        try cleanupSender()
        guard !FileManager.default.fileExists(atPath: sender.path) else {
            throw SuwopError("Actual completion did not release the generated workspace.")
        }
        if received {
            try await OSSharingReceiver.verify(receiver, expected: expected)
        }
        lease = "lease=released files=0"
        result = "callbacks=\(callbacks) cleanup=\(cleanup) receiver=\(received ? 4 : 0)"
        state = completed ? "shared" : "cancelled"
        writeReport()
    }

    private func cleanupSender() throws {
        guard let sender, let workspaces, FileManager.default.fileExists(atPath: sender.path) else { return }
        guard workspaces.contains(path: sender.path) else { throw SuwopError("Generated sender ownership mismatch.") }
        try workspaces.remove(path: sender.path)
        cleanup += 1
        lease = "lease=released files=0"
        result = "callbacks=\(callbacks) cleanup=\(cleanup) receiver=\(received ? 4 : 0)"
    }

    private func writeReport() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let report: [String: Any] = [
                "platform": platform, "state": state, "lease": lease, "result": result,
                "receiver": receiver.path, "sender": sender?.path ?? "", "expected_sha256": expected,
                "native_window": nativeWindow,
                "native_window_events": nativeWindowEvents,
                "evidence_scope": "actual-native-presentation-receiver-lease; Rust-export-covered-separately",
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("report.json"), options: .atomic)
            print("OS_SHARING_REPORT " + root.appendingPathComponent("report.json").path)
        } catch { print("OS_SHARING_REPORT_WRITE_FAILED") }
    }

    #if os(macOS)
        func attach(_ window: NSWindow) {
            presentationWindow = window
            recordNativeWindow("attached")
        }

        func recordNativeWindow(_ stage: String) {
            guard let owned = presentationWindow else {
                nativeWindow = "stage=\(stage) owned=nil"
                return
            }
            let app = NSApplication.shared
            nativeWindow = "stage=\(stage) active=\(app.isActive) key=\(app.keyWindow != nil)"
                + " main=\(app.mainWindow != nil) ownedKey=\(owned.isKeyWindow)"
                + " ownedMain=\(owned.isMainWindow) visible=\(owned.isVisible) canKey=\(owned.canBecomeKey)"
                + " canMain=\(owned.canBecomeMain) policy=\(app.activationPolicy().rawValue)"
                + " runningActive=\(NSRunningApplication.current.isActive)"
                + " activationRequestSent=\(activationRequestSent)"
            nativeWindowEvents.append(nativeWindow)
            nativeWindowEvents = Array(nativeWindowEvents.suffix(32))
            print("OS_SHARING_WINDOW " + nativeWindow)
            writeReport()
        }

        private func requestNativeKeyWindow() {
            recordNativeWindow("button-before-activation")
            guard let owned = presentationWindow else { return }
            // One explicit user action requests foreground status once. The SDK
            // result means the request was sent, never that activation succeeded.
            activationRequestSent = String(NSRunningApplication.current.activate(options: [.activateAllWindows]))
            owned.makeMain()
            owned.makeKeyAndOrderFront(nil)
            owned.makeKey()
            recordNativeWindow("button-after-activation")
        }

        private func requireNativeKeyWindow() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let app = NSApplication.shared
            while ContinuousClock.now < deadline {
                if let owned = presentationWindow, app.isActive, app.keyWindow === owned, owned.isKeyWindow {
                    recordNativeWindow("presentation-ready")
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            recordNativeWindow("presentation-key-window-unavailable")
            throw SuwopError("Generated sharing host did not acquire an actual active key window.")
        }

        private func services(_ items: [Any]) -> [NSSharingService] {
            let provided = items.compactMap { $0 as? URL }
            let service = NSSharingService(
                title: "Generated local receiver",
                image: NSImage(size: NSSize(width: 16, height: 16)),
                alternateImage: nil
            ) { [weak self] in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    do { try OSSharingReceiver.copy(provided, expected: self.urls, into: self.receiver) } catch {
                        self.failure = error
                    }
                }
            }
            return [service]
        }
    #endif
}
