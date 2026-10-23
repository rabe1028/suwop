import SwiftUI

/// Progress invalidates only the status label, never the entire photo grid.
@MainActor final class LibraryProgress: ObservableObject {
    @Published var value: String?
}

struct LibraryProgressText: View {
    @ObservedObject var progress: LibraryProgress
    let fallback: String

    var body: some View {
        Text(progress.value ?? fallback)
    }
}
