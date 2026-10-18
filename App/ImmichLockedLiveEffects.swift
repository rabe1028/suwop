import SuwopShell

@MainActor enum ImmichLockedLiveEffects {
    static let types = [
        "inspectImmichLockedLiveStorage", "readImmichLockedLiveMember", "prepareImmichLockedLive",
        "renewImmichLockedLiveAcquisition", "scheduleImmichLockedLiveAcquisitionExpiry",
        "publishImmichLockedLive", "releaseImmichLockedLive", "releaseImmichLockedLives", "quiesceImmichLockedLive",
    ]

    static func execute(
        _ type: String,
        data: JSONValue,
        access: ImmichLockedLiveNativeAccess
    ) async throws -> JSONValue {
        switch type {
        case "inspectImmichLockedLiveStorage": return try await .from(access.inspect(
                data["pending"].decode(ImmichLockedLivePending.self),
                deadline: data["quoteDeadlineUnixMilliseconds"].decode(Int64.self)
            ))
        case "readImmichLockedLiveMember": return try await .from(access.read(
                data["read"].decode(ImmichLockedLiveRead.self)
            ))
        case "prepareImmichLockedLive": return try await .from(access.prepare(
                data["ticket"].decode(ImmichLockedLiveTicket.self),
                originals: data["originals"].decode([ImmichLockedLiveOriginal].self)
            ))
        case "renewImmichLockedLiveAcquisition": return try await .from(access.renew(
                data["ticket"].decode(ImmichLockedLiveTicket.self),
                previousLeaseID: data["previousLeaseID"].decode(Int64.self),
                lease: data["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
            ))
        case "scheduleImmichLockedLiveAcquisitionExpiry":
            try await access.schedule(
                data["pending"].decode(ImmichLockedLivePending.self),
                lease: data["lease"].decode(ImmichLockedVideoAcquisitionLease.self)
            )
            return .null
        case "publishImmichLockedLive": return try await .from(access.publish(
                data["ticket"].decode(ImmichLockedLiveTicket.self),
                publication: data["publication"].decode(ImmichLockedLivePublication.self)
            ))
        case "releaseImmichLockedLive": return try await .from(access.release(
                data["pending"].decode(ImmichLockedLivePending.self),
                pairLeaseID: data["pairLeaseID"].decode(String?.self)
            ))
        case "releaseImmichLockedLives":
            try await access.release(generation: data["generation"].decode(Int64.self))
            return .null
        case "quiesceImmichLockedLive":
            try await access.quiesce(
                key: data["key"].decode(AssetKey.self), pending: data["pending"].decode(ImmichLockedLivePending?.self)
            )
            return .null
        default: throw SuwopError("未知の Live 原本の入出力です。")
        }
    }
}
