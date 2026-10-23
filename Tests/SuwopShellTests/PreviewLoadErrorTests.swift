import Foundation
import SuwopShell
import Testing

private func isPhotoLibraryUnavailable(_ error: any Error) -> Bool {
    if case .photoLibraryUnavailable = error as? PreviewLoadError {
        return true
    }
    return false
}

@Test func unknownPhotoLibraryErrorDoesNotLeakDomainCodeOrUserInfo() {
    let sentinel = "SENTINEL-c0ffee"
    let underlying = NSError(domain: "UnderlyingDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: sentinel])
    let raw = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1005, userInfo: [
        NSLocalizedDescriptionKey: "\(sentinel) description",
        NSLocalizedFailureReasonErrorKey: "/private/\(sentinel)/reason",
        NSLocalizedRecoverySuggestionErrorKey: "\(sentinel) suggestion",
        NSUnderlyingErrorKey: underlying,
    ])

    let mapped = PreviewLoadError.photoLibrary(raw)

    #expect(isPhotoLibraryUnavailable(mapped))
    let message = mapped.localizedDescription
    for forbidden in [sentinel, "CloudPhotoLibraryErrorDomain", "1005", "Error Domain", "UnderlyingDomain", "Immich"] {
        #expect(!message.contains(forbidden))
    }
    #expect(message.contains("写真アプリ"))
    #expect(message.contains("再試行"))
}

@Test func missingPhotoLibraryErrorUsesAppleFallback() {
    let mapped = PreviewLoadError.photoLibrary(nil)

    #expect(isPhotoLibraryUnavailable(mapped))
    #expect(!mapped.localizedDescription.contains("Immich"))
}

@Test func photoLibraryCancellationStaysCancellation() {
    #expect(PreviewLoadError.photoLibrary(CancellationError()) is CancellationError)
    #expect(PreviewLoadError.photoLibrary(URLError(.cancelled)) is CancellationError)
    let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    #expect(PreviewLoadError.photoLibrary(bridged) is CancellationError)
}

@Test func photoLibraryURLTimeoutNeverMentionsImmich() {
    let errors: [any Error] = [URLError(.timedOut), NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)]
    for error in errors {
        let mapped = PreviewLoadError.photoLibrary(error)

        #expect(isPhotoLibraryUnavailable(mapped))
        #expect(!(mapped is CancellationError))
        #expect(!mapped.localizedDescription.contains("Immich"))
    }
}

@Test func immichHTTP404MessageIsUnchanged() {
    #expect(
        PreviewLoadError.http(404).localizedDescription
            == "Immich にこのプレビューが見つかりません。写真の存在と、サーバー側のプレビュー生成状況を確認してください。（HTTP 404）"
    )
}
