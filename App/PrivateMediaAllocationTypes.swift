import Foundation
import SuwopShell

/// Native physical ownership only. Neither a consumer nor a file ID grants read authority.
enum PrivateMediaAllocation {
    struct Owner: Sendable, Equatable {
        let id = UUID()
        let resources: [AssetKey]
    }

    struct File: Sendable {
        let id: String
        let url: URL
    }

    struct Limit: Sendable, Equatable {
        let fileID: String
        let maximum: Int64
        let mode: ImmichLockedVideoCommitmentMode
    }

    struct Reservation: Sendable, Equatable {
        let id: UUID
        let bytes: Int64
    }

    struct Contract: Sendable, Equatable {
        let totalReceived: Int64
        let diskCeiling: Int64
        let headroom: Int64
        let representations: [Reservation]
    }

    struct FileState: Sendable {
        var file: File
        var physicalID = ""
        var limit: Limit?
        var claimedThrough: Int64 = 0
        var received: Int64 = 0
        var written: Int64 = 0
        var finished = false
        var failed = false
        var original = true
    }

    struct Consumer: Sendable {
        let owner: Owner
        let volume: PrivateVideoVolume.Measurement
        var files: [String: FileState]
        var contract: Contract?
        var failed = false
        var reservations: [UUID: Int64] = [:]
    }

    static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, lhs >= 0, rhs >= 0 else { throw capacityError() }
        return sum
    }

    static func capacityError() -> SuwopError {
        SuwopError("動画を取得する空き容量が不足しています。")
    }
}

/// Local presentation container suffixes, selected from actual native content, never server names or MIME.
enum PrivateMediaFileSuffix: String, Sendable {
    case jpeg = "jpg", heic, heif, quickTime = "mov", mpeg4 = "mp4"
}
