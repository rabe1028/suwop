import SuwopShell
import SwiftUI

@main @MainActor struct SuwopApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup {
            LibrarySceneRoot(model: model)
        }
    }
}

private struct LibrarySceneRoot: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.scenePhase) private var phase
    @State private var sceneID = UUID().uuidString

    var body: some View {
        GalleryView(model: model, sceneID: sceneID)
            .environment(\.protectionSceneID, sceneID)
            .background(NativeScenePresentationAnchor(sceneID: sceneID))
            .task { model.start() }
            .onChange(of: phase, initial: true) { _, phase in
                let value: ProtectionScenePhase = switch phase {
                case .active: .active
                case .inactive: .inactive
                case .background: .background
                @unknown default: .background
                }
                model.semanticSearch?.scene(id: sceneID, active: phase == .active)
                model.protection.sceneChanged(sceneID: sceneID, phase: value)
                model.immichLocked.sceneChanged(sceneID: sceneID, phase: value)
                model.immichArchive.sceneChanged(sceneID: sceneID, phase: value)
                model.ordinarySelected.sceneChanged(sceneID: sceneID, phase: value)
                model.ordinaryLivePairImages.sceneChanged(sceneID: sceneID, phase: value)
            }
            .onDisappear {
                model.semanticSearch?.scene(id: sceneID, active: false)
                model.protection.close(sceneID: sceneID)
                model.immichLocked.close(sceneID: sceneID)
                model.immichArchive.close(sceneID: sceneID)
                model.ordinarySelected.close(sceneID: sceneID)
                model.ordinaryLivePairImages.close(sceneID: sceneID)
            }
    }
}
