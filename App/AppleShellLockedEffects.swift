import SuwopShell

extension AppleShell {
    func immichLockedEffect(_ type: String, data: JSONValue, http: HTTPExecutor) async throws -> JSONValue {
        if ImmichLockedLiveEffects.types.contains(type) {
            return try await ImmichLockedLiveEffects.execute(type, data: data, access: immichLockedLiveAccess)
        }
        if ImmichLockedVideoEffects.types.contains(type) {
            return try await ImmichLockedVideoEffects.execute(type, data: data, access: immichLockedVideoAccess)
        }
        switch type {
        case "capturePrivateMediaKey":
            try immichLockedLiveAccess.consumers.captureForSelectedWrite(key: data["key"].decode(AssetKey.self))
            return .null
        case "readImmichLockedImage": return try await .from(immichLockedAccess.read(
                data["ticket"].decode(ImmichLockedImageTicket.self), http: http
            ))
        case "publishImmichLockedImage": return try await .from(immichLockedAccess.publish(
                data["ticket"].decode(ImmichLockedImageTicket.self), stagedID: data["stagedID"].decode(String.self)
            ))
        case "releaseImmichLockedImage":
            try immichLockedAccess.release(stagedID: data["stagedID"].decode(String.self))
            return .null
        case "releaseImmichLockedImages":
            try immichLockedAccess.release(generation: data["generation"].decode(Int64.self))
            return .null
        case "scheduleImmichLockedExpiry", "scheduleImmichLockedCheck":
            try immichLockedTimerEffect?(ImmichLockedTimer(
                expiry: type == "scheduleImmichLockedExpiry",
                grantID: data["grantID"].decode(String.self),
                generation: data["generation"].decode(Int64.self),
                leaseID: data["leaseID"].decode(Int64.self),
                milliseconds: data["milliseconds"].decode(Int64.self),
                deadlineUnixMilliseconds: data["deadlineUnixMilliseconds"].decode(Int64.self)
            ))
            return .null
        default: throw SuwopError("未知の Immich ロック写真の入出力です。")
        }
    }
}
