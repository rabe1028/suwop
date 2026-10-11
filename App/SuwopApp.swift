import SuwopShell
import SwiftUI

@main @MainActor struct SuwopApp: App {
    @StateObject private var model = LibraryModel()
    var body: some Scene {
        WindowGroup {
            GalleryView(model: model)
                .task { model.start() }
        }
    }
}
