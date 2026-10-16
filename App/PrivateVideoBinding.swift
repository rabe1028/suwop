import Foundation
import SuwopShell

/// The mutable phase is deliberately excluded from immutable request ownership.
struct PrivateVideoBinding: Sendable, Equatable {
    let requestID: String
    let entryID: String
    let grantID: String
    let sceneID: String
    let generation: Int64
    let provider: Provider
    let scope: String
    let assetID: String

    init(_ pending: ImmichLockedVideoPending) {
        requestID = pending.requestID
        entryID = pending.entryID
        grantID = pending.grantID
        sceneID = pending.sceneID
        generation = pending.generation
        provider = pending.key.provider
        scope = pending.key.scope
        assetID = pending.key.assetID
    }
}
