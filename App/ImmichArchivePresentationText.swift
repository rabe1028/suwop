import SuwopShell

extension ImmichArchiveDestination {
    var title: String {
        switch self {
        case .timeline: "タイムライン"
        case .archive: "アーカイブ"
        }
    }
}
