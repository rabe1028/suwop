import SuwopShell

@MainActor enum ImmichLockedVideoEffects {
    static let types = [
        "inspectImmichLockedVideoStorage", "readImmichLockedVideo", "prepareImmichLockedVideo",
        "releaseImmichLockedVideo", "releaseImmichLockedVideos", "retireImmichLockedVideoPending",
        "renewImmichLockedVideoAcquisition", "scheduleImmichLockedVideoAcquisitionExpiry",
        "quiesceImmichLockedVideo",
    ]

    static func isCleanup(_ type: String) -> Bool {
        ["releaseImmichLockedVideo", "releaseImmichLockedVideos", "retireImmichLockedVideoPending"].contains(type)
    }

    static func execute(
        _ type: String, data: JSONValue, access: ImmichLockedVideoNativeAccess
    ) async throws -> JSONValue {
        switch type {
        case "inspectImmichLockedVideoStorage": return try await .from(access.inspect(
                data["pending"].decode(ImmichLockedVideoPending.self)
            ))
        case "readImmichLockedVideo": return try await .from(access.read(
                data["ticket"].decode(ImmichLockedVideoTicket.self)
            ))
        case "prepareImmichLockedVideo": return try await .from(access.prepare(
                data["ticket"].decode(ImmichLockedVideoTicket.self), stagedID: data["stagedID"].decode(String.self)
            ))
        case "renewImmichLockedVideoAcquisition": return try await .from(access.renew(
                data["ticket"].decode(ImmichLockedVideoTicket.self),
                previousLeaseID: data["previousLeaseID"].decode(Int64.self),
                lease: data["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
            ))
        case "scheduleImmichLockedVideoAcquisitionExpiry":
            try await access.scheduleAcquisitionExpiry(
                data["pending"].decode(ImmichLockedVideoPending.self),
                lease: data["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
            )
            return .null
        case "quiesceImmichLockedVideo":
            let pending = try data["pending"].decode(ImmichLockedVideoPending?.self)
            try await access.quiesce(key: data["key"].decode(AssetKey.self), pending: pending)
            return .null
        case "retireImmichLockedVideoPending":
            let join = try access.retireCapturedPending(
                data["pending"].decode(ImmichLockedVideoPending.self),
                deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                retryCleanup: data["retryCleanup"].decode(Bool.self)
            )
            try await join.value
            return .null
        case "releaseImmichLockedVideo":
            try await access.release(
                data["pending"].decode(ImmichLockedVideoPending.self),
                leaseID: data["leaseID"].decode(String.self),
                retryCleanup: data["retryCleanup"].decode(Bool.self)
            )
            return .null
        case "releaseImmichLockedVideos":
            try await access.release(
                generation: data["generation"].decode(Int64.self),
                retryCleanup: data["retryCleanup"].decode(Bool.self)
            )
            return .null
        default: throw SuwopError("未知の動画の入出力です。")
        }
    }
}
