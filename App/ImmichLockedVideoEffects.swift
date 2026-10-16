import SuwopShell

@MainActor enum ImmichLockedVideoEffects {
    static let types = [
        "inspectImmichLockedVideoStorage", "readImmichLockedVideo", "prepareImmichLockedVideo",
        "releaseImmichLockedVideo", "releaseImmichLockedVideos",
    ]

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
        case "releaseImmichLockedVideo":
            try await access.release(
                data["pending"].decode(ImmichLockedVideoPending.self), leaseID: data["leaseID"].decode(String.self)
            )
            return .null
        case "releaseImmichLockedVideos":
            try await access.release(generation: data["generation"].decode(Int64.self))
            return .null
        default: throw SuwopError("未知の動画の入出力です。")
        }
    }
}
