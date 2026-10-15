import SuwopShell

extension AppleShell {
    func submissionPermit(for request: HttpRequest) async throws -> NativeSubmissionPermit? {
        guard request.immichVisibilityAuthorization == nil || request.immichArchiveAuthorization == nil else {
            throw CancellationError()
        }
        if let authorization = request.immichVisibilityAuthorization {
            return try await immichLockedAccess.visibilitySubmission(authorization)
        }
        if let authorization = request.immichArchiveAuthorization {
            return try await archiveAccess.submission(authorization, request: request)
        }
        return nil
    }

    func confirmImmichArchive(_ prompt: ImmichArchivePrompt, context: ContentPresentationContext) async throws -> Bool {
        guard context.permits(), await archiveAccess.permits(prompt) else { return false }
        let result: Bool
        #if SUWOP_VRT
            if let effect = archiveAccess.confirmationEffect {
                result = try await effect(prompt, context)
            } else {
                result = try await archiveConfirmation.present(prompt, context: context)
            }
        #else
            result = try await archiveConfirmation.present(prompt, context: context)
        #endif
        guard context.permits(), await archiveAccess.permits(prompt) else { return false }
        return result
    }
}
