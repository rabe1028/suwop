import SwiftUI

@main @MainActor struct AcceptanceHost: App {
    var body: some Scene {
        WindowGroup { AcceptanceScreen() }
    }
}

private struct AcceptanceScreen: View {
    @State private var result = "RUNNING"
    @State private var started = false
    @State private var visibilityEvidence = ""
    @State private var visibilityOutcome = ""

    var body: some View {
        VStack {
            Text(result).accessibilityIdentifier("nativeAcceptanceResult")
            Text(visibilityEvidence).accessibilityIdentifier("nativeVisibilityEvidence")
            Text(visibilityOutcome).accessibilityIdentifier("nativeVisibilityOutcome")
        }
        .task {
            guard !started else { return }
            started = true
            let phase = CommandLine.arguments.last ?? ""
            do {
                try await NativeScenario.run(phase)
                if phase.hasPrefix("visibility-") {
                    let fixture = try NativeVisibilityScenario.read()
                    visibilityEvidence = fixture.evidence?.rawValue ?? ""
                    visibilityOutcome = fixture.hideOutcome.rawValue
                }
                result = "PASS \(phase)"
            } catch {
                result = "FAIL \(phase): \(error.localizedDescription)"
            }
        }
    }
}
