import Foundation
import SuwopShell

extension AppleShell {
    func amazonEffect(_ type: String, data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        switch type {
        case "amazonHttp":
            let request = try data["request"].decode(AmazonRequest.self)
            if let authorization = request.http.ordinaryContentAuthorization {
                _ = try await ordinaryContent.validate(
                    keys: authorization.sourceKeys,
                    context: context,
                    expectedRevision: authorization.expectedRevision,
                    purpose: authorization.purpose
                )
            }
            try context.requireCurrent()
            let permit = request.http.method == "GET" ? nil
                : amazonSubmission.permit(deadline: Int64(Date().timeIntervalSince1970 * 1000) + 30000)
            let response = try await amazonHTTP.execute(request, submission: permit)
            if let authorization = request.http.ordinaryContentAuthorization {
                _ = try await ordinaryContent.validate(
                    keys: authorization.sourceKeys,
                    context: context,
                    expectedRevision: authorization.expectedRevision,
                    purpose: authorization.purpose
                )
            }
            return try .from(response)
        case "amazonHashFile":
            let request = try FileHashRequest()
            let path = try data["path"].decode(String.self)
            let worker = Task.detached(priority: .utility) { try request.readAmazon(URL(fileURLWithPath: path)) }
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: {
                request.cancel()
                worker.cancel()
            }
            return try .from(result)
        case "removeAmazonCredential":
            try AmazonCredentials.remove(data["account"].decode(String.self))
            return .null
        default: throw SuwopError("不正なAmazon Photos操作です。")
        }
    }

    /// Every failure before the native task resumes is returned as unsent evidence.
    /// Owner and cancellation checks are made here because the generic dispatcher
    /// would throw them as ambiguous errors. Later failures are always thrown.
    func amazonUpload(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let request: AmazonRequest
        let permit: NativeSubmissionPermit
        do {
            try context.requireOwner(presentationEpoch)
            try Task.checkCancellation()
            request = try data["request"].decode(AmazonRequest.self)
            if let authorization = request.http.ordinaryContentAuthorization {
                _ = try await ordinaryContent.validate(
                    keys: authorization.sourceKeys,
                    context: context,
                    expectedRevision: authorization.expectedRevision,
                    purpose: authorization.purpose
                )
            }
            try context.requireCurrent()
            permit = amazonSubmission.permit(deadline: Int64(Date().timeIntervalSince1970 * 1000) + 30000)
        } catch {
            return try .from(AmazonUploadSubmission(failure: (error as? SuwopError)?.message, submitted: false))
        }
        let submission = try await amazonHTTP.upload(request, permit: permit)
        if submission.submitted, let authorization = request.http.ordinaryContentAuthorization {
            _ = try await ordinaryContent.validate(
                keys: authorization.sourceKeys,
                context: context,
                expectedRevision: authorization.expectedRevision,
                purpose: authorization.purpose
            )
        }
        return try .from(submission)
    }
}
