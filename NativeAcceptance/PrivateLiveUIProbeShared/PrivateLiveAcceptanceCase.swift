import Foundation

/// Closed test inventory, never a product authorization or operation.
enum PrivateLiveAcceptanceCase: String, Codable, CaseIterable {
    case fullPlayback = "testActualFullPlaybackHasCurrentCallbacksAndChangingRenderedSurfaceFrames"
    case activeReplay = "testSingleReplayDuringActualPlaybackRestartsFullMotionAfterActualEnd"
    case queuedRevocation = "testOwnerRevocationAtActualEndCancelsQueuedReplayBeforeNativeStart"
    case sharedSurface = "testSameAccessOldSurfaceDetachPreservesNewSurfaceAndSharedStateClaim"
    case windowOwnership = "testUnregisterHiddenWindowAndExactReplacementImmediatelyShield"
    case freshAttachment = "testFreshAttachmentCannotAssignAfterOwnerUnregisterOrRequestRetirement"
    case reusedSurface = "testReusedNativeSurfaceBindsNewAccessAndDetachStopsCurrentObject"
    case oldDeadline = "testPublishedSurfaceSurvivesOldAcquisitionDeadlineWithRealSessionCheck"
    case windowEvents = "testActualPlatformWindowUnavailableEventsClearNativeObject"
    case hostedDisappear = "testActualSwiftUIContentDisappearanceStopsAndClearsHostedSurface"

    func accepts(_ operation: String) -> Bool {
        switch operation {
        case "start", "observe", "close": true
        case "replay": self == .activeReplay
        case "invalidate": self == .fullPlayback
        case "window-miniaturize", "window-deactivate", "window-reactivated": self == .windowEvents
        case "scenario": ![.fullPlayback, .activeReplay, .windowEvents].contains(self)
        default: false
        }
    }

    var nativeChecks: [String] {
        switch self {
        case .fullPlayback, .activeReplay: [] // Actual compositor samples are asserted in the UI runner.
        case .queuedRevocation: [
                "actual-end",
                "exact-dispatch",
                "no-new-begin",
                "synchronous-shield",
                "no-native-failure",
            ]
        case .sharedSurface: [
                "new-surface-claim",
                "old-detach-isolated",
                "controls-preserved",
                "new-replay",
                "new-detach",
            ]
        case .windowOwnership: [
                "unregister-shield",
                "register-reattach",
                "hidden-shield",
                "visible-reattach",
                "replacement-shield",
            ]
        case .freshAttachment: ["unregistered-rejected", "retired-rejected", "zero-assignment"]
        case .reusedSurface: ["replacement-shield", "same-consumer", "new-attachment", "detach-clears"]
        case .oldDeadline: ["past-old-deadline", "native-retained", "current-access", "old-expiry-rejected"]
        case .windowEvents: [
                "miniaturized-shield",
                "deminiaturized-reattach",
                "deactivated-shield",
                "reactivated-reattach",
                "closed-shield",
            ]
        case .hostedDisappear: [
                "actual-swiftui-attachment",
                "actual-disappearance-clears",
                "muted",
                "domain-access-retained",
            ]
        }
    }
}
