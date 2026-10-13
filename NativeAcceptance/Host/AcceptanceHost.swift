import SwiftUI

@main @MainActor struct AcceptanceHost: App {
    var body: some Scene {
        WindowGroup { AcceptanceScreen() }
    }
}

private struct AcceptanceScreen: View {
    @State private var result = "RUNNING"
    @State private var started = false

    var body: some View {
        Text(result).accessibilityIdentifier("nativeAcceptanceResult")
            .task {
                guard !started else { return }
                started = true
                let phase = CommandLine.arguments.last ?? ""
                do {
                    try await NativeScenario.run(phase)
                    result = "PASS \(phase)"
                } catch {
                    result = "FAIL \(phase): \(error.localizedDescription)"
                }
            }
    }
}
