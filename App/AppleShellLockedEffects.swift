import SuwopShell

extension AppleShell {
    func immichLockedEffect(_ type: String, data: JSONValue, http: HTTPExecutor) async throws -> JSONValue {
        switch type {
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
