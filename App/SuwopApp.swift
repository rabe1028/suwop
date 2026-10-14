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
            .task { model.start() }
            .onChange(of: phase, initial: true) { _, phase in
                let value: ProtectionScenePhase = switch phase {
                case .active: .active
                case .inactive: .inactive
                case .background: .background
                @unknown default: .background
                }
                model.protection.sceneChanged(sceneID: sceneID, phase: value)
            }
            .onDisappear { model.protection.close(sceneID: sceneID) }
    }
}
