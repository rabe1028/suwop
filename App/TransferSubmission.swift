import Foundation
import SuwopShell

/// Native submission gate for one prepared HTTP source deletion of an explicit Move.
///
/// Rust owns the transfer state machine, the deletion authority and the route. This
/// helper only decides whether the already prepared request may still be handed to
/// the network stack: it binds the deletion to the presentation context captured when
/// the user command started and to the shared `NativeSubmissionGate` that every
/// observed PhotoKit, protection and private-session change invalidates. The returned
/// permit is checked again under the gate's lock at the moment `HTTPExecutor` resumes
/// the task, so a change observed after this call still refuses submission.
///
/// Every refusal is a `CancellationError` raised before any network task exists. The
/// caller decides how to report that; this helper fabricates no "not submitted" proof.
enum TransferSubmission {
    /// Deletions are issued immediately after preflight; a permit that outlives this
    /// window is stale, whatever the gate says.
    static let windowMilliseconds: Int64 = 30000

    /// Issue a permit for one DELETE with a JSON body and no other authority attached.
    ///
    /// Synchronous on the main actor: the gate epoch is captured first, then the context
    /// is validated, so an invalidation that lands after the check is still observed by
    /// `NativeSubmissionPermit.submit`. The full epoch is required; the all-Immich
    /// presentation bypass is deliberately not used because the destination copies of
    /// an Immich→Apple Move live in Apple Photos.
    @MainActor
    static func permit(
        request: HttpRequest,
        context: ContentPresentationContext,
        owner: ContentPresentationEpoch,
        gate: NativeSubmissionGate,
        now: Date = Date()
    ) throws -> NativeSubmissionPermit {
        let permit = gate.permit(deadline: Int64(now.timeIntervalSince1970 * 1000) + windowMilliseconds)
        try context.requireOwner(owner)
        try context.requireCurrent()
        try Task.checkCancellation()
        try requireDeletionShape(request)
        return permit
    }

    /// A source deletion is a body-only DELETE. Multipart uploads, downloads, form
    /// fields and any private, archive or ordinary-read authorization are different
    /// effects and must not borrow this permit.
    static func requireDeletionShape(_ request: HttpRequest) throws {
        guard request.method == "DELETE",
              request.files.isEmpty,
              request.fields.isEmpty,
              request.downloadPath == nil,
              request.immichArchiveAuthorization == nil,
              request.immichVisibilityAuthorization == nil,
              request.ordinaryContentAuthorization == nil
        else { throw CancellationError() }
        if case .null = request.body {
            throw CancellationError()
        }
    }
}
