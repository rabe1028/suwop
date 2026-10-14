import AppKit
import SuwopShell
import XCTest

@MainActor private final class PickerProbe {
    var shown: NSSharingServicePicker?
    var closes = 0
    var completed = false
    var finished = false
    var error: Error?

    var hooks: SharingPickerTestHooks {
        SharingPickerTestHooks(
            presentationView: NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120)),
            show: { self.shown = $0 },
            close: { _ in self.closes += 1 }
        )
    }
}

final class SharingVisibilityTests: XCTestCase {
    @MainActor func testInvalidationClosesOnlyAppleOrLegacyPreselectionAndRetainsLeaseUntilDelegate() async throws {
        let apple = AssetKey(provider: .apple, scope: "generated", assetID: "apple")
        let immich = AssetKey(provider: .immich, scope: "generated", assetID: "immich")
        let cases: [[AssetKey]?] = [[immich], [apple], [apple, immich], [], nil]
        for keys in cases {
            try await withPresentation(sourceKeys: keys) { service, probe, picker, _ in
                service.invalidateForContentChange()
                let expectedCloses = keys == [immich] ? 0 : 1
                XCTAssertEqual(probe.closes, expectedCloses)
                XCTAssertFalse(probe.finished)
                XCTAssertNil(probe.error)
                // Observing close alone must not release files. Only the native
                // nil-selection callback resolves this preselection lease.
                picker.delegate?.sharingServicePicker?(picker, didChoose: nil)
                try await self.waitUntil { probe.finished }
                XCTAssertEqual(probe.completed, false)
                XCTAssertNil(probe.error)
                print("SHARING_PRESELECTION_PASS \(keys?.map(\.provider) ?? []) close=\(probe.closes)")
            }
        }
    }

    @MainActor func testAppleSelectionKeepsLeaseThroughInvalidationAndLateNilSelection() async throws {
        let apple = AssetKey(provider: .apple, scope: "generated", assetID: "apple")
        try await withPresentation(sourceKeys: [apple]) { service, probe, picker, url in
            let nativeService = self.generatedService()
            let delegate = try XCTUnwrap(picker.delegate?.sharingServicePicker?(picker, delegateFor: nativeService))
            service.invalidateForContentChange()
            XCTAssertEqual(probe.closes, 0)
            XCTAssertFalse(probe.finished)
            picker.delegate?.sharingServicePicker?(picker, didChoose: nil)
            // Drain the MainActor task scheduled by the nil-selection delegate.
            for _ in 0 ..< 3 {
                await Task.yield()
            }
            XCTAssertFalse(probe.finished)
            XCTAssertNil(probe.error)
            delegate.sharingService?(nativeService, didShareItems: [url])
            try await self.waitUntil { probe.finished }
            XCTAssertEqual(probe.completed, true)
            XCTAssertNil(probe.error)
            print("SHARING_SELECTED_LEASE_PASS")
        }
    }

    @MainActor private func withPresentation(
        sourceKeys: [AssetKey]?,
        body: @MainActor (SystemSharing, PickerProbe, NSSharingServicePicker, URL) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-fixture-\(UUID()).txt")
        try Data("generated sharing fixture".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let service = SystemSharing()
        let probe = PickerProbe()
        service.pickerTestHooks = probe.hooks
        let task = Task { @MainActor in
            do {
                probe.completed = try await service.present(SharePresentation(
                    files: [ShareFile(name: url.lastPathComponent, path: url.path)], sourceKeys: sourceKeys
                ))
            } catch {
                probe.error = error
                print("SHARING_PRESENTATION_ERROR \(error.localizedDescription)")
            }
            probe.finished = true
        }
        try await waitUntil { probe.shown != nil || probe.error != nil }
        if let error = probe.error {
            await task.value
            XCTFail("Native sharing fixture presentation failed: \(error.localizedDescription)")
            throw error
        }
        let picker = try XCTUnwrap(probe.shown)
        do {
            try await body(service, probe, picker, url)
        } catch {
            // Even a failed assertion must finish the native lease before removing
            // its fixture. Drive the real completion delegate without a handoff.
            (picker.delegate as? NSSharingServiceDelegate)?.sharingService?(
                generatedService(), didFailToShareItems: [url], error: error
            )
            await task.value
            throw error
        }
        await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor private func generatedService() -> NSSharingService {
        NSSharingService(
            title: "Generated fixture service",
            image: NSImage(size: NSSize(width: 8, height: 8)),
            alternateImage: nil
        ) {
            XCTFail("Fixture must not be handed to a sharing service.")
        }
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native sharing delegate did not reach the expected state.")
        throw SuwopError("Sharing test timed out")
    }
}
