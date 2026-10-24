import SwiftUI

extension LibraryModel {
    /// Whether the library has applied its stored settings and finished the refresh that
    /// reconnects Immich after start. A snapshot published mid-update does not count.
    var settled: Bool {
        started && work == nil && view != nil && !(pendingRefresh && libraryReady)
    }

    /// Waits until `settled`; returns early when cancelled.
    func untilSettled() async {
        for await _ in $work.values where settled {
            return
        }
    }
}
