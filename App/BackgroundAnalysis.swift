#if os(iOS)
    import BackgroundTasks
    import Foundation

    /// Continues photo analysis in the background while the device charges. The system
    /// chooses when the task runs and cancels it when its time expires.
    @MainActor enum BackgroundAnalysis {
        static let identifier = "jp.rabe1028.suwop.ios.analysis"
        /// Set when the library connects; the task completes immediately without it.
        weak static var search: SemanticSearchModel?

        /// Must run before the app finishes launching.
        static func register() {
            _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated { run(task) }
            }
        }

        /// Photo sources may need the network for originals, so the task waits for it too.
        /// Submission fails where background tasks are unavailable, such as the simulator.
        static func schedule() {
            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = true
            try? BGTaskScheduler.shared.submit(request)
        }

        private static func run(_ task: BGTask) {
            guard let search else {
                task.setTaskCompleted(success: false)
                return
            }
            let work = Task { await search.analyzeInBackground() }
            task.expirationHandler = { work.cancel() }
            Task {
                let finished = await work.value
                task.setTaskCompleted(success: finished)
            }
        }
    }
#endif
