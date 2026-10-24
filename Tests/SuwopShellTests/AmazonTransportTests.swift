import Foundation
import SuwopShell
import Testing

@Test func revokedSubmissionNeverStartsAnAmazonUploadTask() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://example.invalid/upload"))
    do {
        _ = try await BoundedHTTPData.load(
            URLRequest(url: url),
            session: session,
            limit: 1024,
            allowRedirects: false,
            submit: { task in
                #expect(task.state == .suspended)
                throw CancellationError()
            }
        )
        Issue.record("A revoked submission must fail before the network task resumes")
    } catch is CancellationError {}
}

private func refuseSubmission() throws {
    throw CancellationError()
}

@Test func refusedAmazonSubmissionIsReportedAsNeverResumed() async throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://example.invalid/upload"))
    let mark = NativeSubmissionMark()
    do {
        _ = try await BoundedHTTPData.load(
            URLRequest(url: url),
            session: session,
            limit: 1024,
            allowRedirects: false,
            submit: { task in
                try refuseSubmission()
                mark.resume(task)
            }
        )
        Issue.record("A refused submission must fail before the network task resumes")
    } catch is CancellationError {}
    #expect(!mark.submitted)
}

@Test func sealedSubmissionMarkNeverStartsALateTask() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://example.invalid/upload"))
    let task = session.dataTask(with: url)
    let mark = NativeSubmissionMark()
    #expect(mark.sealUnsubmitted())
    mark.resume(task)
    #expect(task.state == .canceling || task.state == .completed)
    #expect(!mark.submitted)
    #expect(mark.sealUnsubmitted())
}

@Test func attemptedSubmissionCanNeverBeSealedAsUnsent() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "https://example.invalid/upload"))
    let task = session.dataTask(with: url)
    // Cancelled while suspended, so the resume attempt performs no network I/O.
    task.cancel()
    let mark = NativeSubmissionMark()
    mark.resume(task)
    #expect(mark.submitted)
    #expect(!mark.sealUnsubmitted())
    #expect(mark.submitted)
}

@Test func amazonRedirectsReturnToTheCoreInsteadOfForwardingCookies() throws {
    let url = try #require(URL(string: "https://www.amazon.co.jp/drive/v1/nodes"))
    let destination = try #require(URL(string: "https://example.amazonaws.com/original"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let receiver = BoundedHTTPData(limit: 1024, allowRedirects: false)
    let task = session.dataTask(with: url)
    receiver.urlSession(
        session,
        task: task,
        willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: destination)
    ) {
        #expect($0 == nil)
    }
    task.cancel()
}

@Test func amazonNativeHashMatchesTheIndependentReferenceVector() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    try Data("abc".utf8).write(to: path)
    let result = try FileHashRequest().readAmazon(path)
    #expect(result.md5 == "900150983cd24fb0d6963f7d28e17f72")
    #expect(result.signature.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(result.signature.bytes == 3)
}
