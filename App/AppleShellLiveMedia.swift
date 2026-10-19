import Foundation
import SuwopShell

extension AppleShell {
    func configureLiveMedia(runtime: RustRuntime) {
        let live = immichLockedLiveAccess
        let video = immichLockedVideoAccess
        let raster = immichLockedAccess
        live.configure(runtime: runtime)
        live.cancelOtherMedia = { [weak video, weak raster] in
            guard let video else { return nil }
            let captured = Array(video.consumerOwners.values)
            video.invalidate()
            let rasterTask = raster?.cancellationHandle()
            return Task { @MainActor in
                // Existing raster cancellation is a joined failure, not a failed resource cleanup receipt.
                _ = await rasterTask?.result
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                for owner in captured where !owner.released {
                    guard let handle = owner.handle else { throw CancellationError() }
                    _ = try await video.consumerRegistry.retireAndJoinWithoutRetry(owner: handle, deadline: deadline)
                }
            }
        }
        video.cancelOtherMedia = { [weak live, weak raster] in
            let liveTask = live?.cancellationHandle()
            let rasterTask = raster?.cancellationHandle()
            return Task { @MainActor in
                _ = await rasterTask?.result
                try await liveTask?.value
            }
        }
        raster.beforeRead = { [weak live, weak video] in
            let cleanup = live?.cancellationHandle()
            await video?.joinCleanup()
            try await cleanup?.value
        }
    }
}
