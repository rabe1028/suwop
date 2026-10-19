import Foundation

/// Generator input only. Verify.swift deliberately does not import this pattern.
enum Pattern {
    static let identifier = "A762B1E3-9D24-4B70-AD53-FA1642C8039E"
    static let width = 96
    static let height = 96
    static let frameCount = 48
    static let framesPerSecond: Int32 = 12
    static let stillIndex = 18

    static func rgba(frame: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let step = frame * 4 % 128
        let left = 8 + min(step, 128 - step)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let checker = (x / 12 + min(y, height - 1 - y) / 12) % 2 == 0
                bytes[offset] = checker ? 24 : 40
                bytes[offset + 1] = checker ? 66 : 98
                bytes[offset + 2] = checker ? 106 : 136
                if (left ..< left + 16).contains(x), (36 ..< 60).contains(y) {
                    bytes[offset] = 242
                    bytes[offset + 1] = 44
                    bytes[offset + 2] = 36
                }
            }
        }
        return bytes
    }
}
