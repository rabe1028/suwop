import Foundation
import SuwopShell

extension AppleShell {
    func executeHTTP(_ request: HttpRequest) async throws -> HttpResponse {
        let submission = try await submissionPermit(for: request)
        #if SUWOP_VRT
            if let httpTransportEffect {
                try submission?.submit {}
                return try await httpTransportEffect(request)
            }
        #endif
        return try await http.execute(request, submission: submission)
    }

    func authorizedHTTP(_ request: HttpRequest, context: ContentPresentationContext) async throws -> JSONValue {
        if request.immichVisibilityAuthorization != nil || request.immichArchiveAuthorization != nil {
            return try await .from(executeHTTP(request))
        }
        guard let authorization = request.ordinaryContentAuthorization else {
            return try await .from(executeHTTP(request))
        }
        _ = try await ordinaryContent.validate(
            keys: authorization.sourceKeys,
            context: context,
            expectedRevision: authorization.expectedRevision,
            purpose: authorization.purpose
        )
        let response = try await executeHTTP(request)
        _ = try await ordinaryContent.validate(
            keys: authorization.sourceKeys,
            context: context,
            expectedRevision: authorization.expectedRevision,
            purpose: authorization.purpose
        )
        return try .from(response)
    }
}
