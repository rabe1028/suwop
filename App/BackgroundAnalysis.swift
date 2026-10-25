#if os(iOS)
    import BackgroundTasks
    import Foundation

    /// Continues photo analysis in the background while the device charges. The system
    /// chooses when the task runs and cancels it when its time expires.
    @MainActor enum BackgroundAnalysis {
        static let identifier = "jp.rabe1028.suwop.ios.analysis"
        /// The app's library, retained for launches that deliver the task without a scene.
        private static var library: LibraryModel?

        /// Must run before the app finishes launching.
        static func register(library: LibraryModel) {
            self.library = library
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
            guard let library, let search = library.semanticSearch else {
                task.setTaskCompleted(success: false)
                return
            }
            // A launch without a scene has not started the library; analysis waits for it to settle.
            library.start()
            let work = Task { await search.analyzeInBackground() }
            task.expirationHandler = { work.cancel() }
            Task {
                let finished = await work.value
                task.setTaskCompleted(success: finished)
            }
        }
    }
#endif
