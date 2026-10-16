import Darwin
import Foundation
import SuwopShell

/// A measurement of the actual private-file volume, never a filesystem reservation.
struct PrivateVideoVolume: Sendable {
    enum CapacityClass: Sendable {
        case importantUsage
        case available
    }

    struct Measurement: Sendable {
        let availableBytes: Int64
        let allocationUnitBytes: Int64
        let capacityClass: CapacityClass
        let volumeIdentifier: String
    }

    let directory: URL

    func measure() throws -> Measurement {
        var freshDirectory = directory
        freshDirectory.removeAllCachedResourceValues()
        let values = try freshDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIdentifierKey,
        ])
        let available: Int64
        let capacityClass: CapacityClass
        if let important = values.volumeAvailableCapacityForImportantUsage {
            guard important >= 0 else { throw SuwopError("動画を取得する空き容量を確認できません。") }
            available = important
            capacityClass = .importantUsage
        } else if let fallback = values.volumeAvailableCapacity, fallback >= 0 {
            available = Int64(fallback)
            capacityClass = .available
        } else {
            throw SuwopError("動画を取得する空き容量を確認できません。")
        }
        guard let identifier = values.volumeIdentifier else {
            throw SuwopError("動画の保存先を確認できません。")
        }
        var information = statfs()
        guard statfs(directory.path, &information) == 0, information.f_bsize > 0 else {
            throw SuwopError("動画の保存先を確認できません。")
        }
        return Measurement(
            availableBytes: available,
            allocationUnitBytes: Int64(information.f_bsize),
            capacityClass: capacityClass,
            volumeIdentifier: String(describing: identifier)
        )
    }
}
