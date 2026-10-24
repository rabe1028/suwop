import SuwopShell

extension AppleShell {
    func transferDeletion(_ data: JSONValue, context: ContentPresentationContext) async throws -> JSONValue {
        let request = try data.decode(HttpRequest.self)
        let permit = try TransferSubmission.permit(
            request: request, context: context, owner: presentationEpoch, gate: amazonSubmission
        )
        return try await .from(executeHTTP(request, preparedSubmission: permit))
    }

    private func executeHTTP(
        _ request: HttpRequest,
        preparedSubmission: NativeSubmissionPermit? = nil
    ) async throws -> HttpResponse {
        let submission: NativeSubmissionPermit? = if let preparedSubmission {
            preparedSubmission
        } else {
            try await submissionPermit(for: request)
        }
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
