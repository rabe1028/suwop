import Foundation
import SuwopShell

/// Decode the RFC3339 timestamp emitted by Rust, including AutoSi fractions.
/// Reject malformed/calendar-normalized dates before native submission; never
/// turn an invalid requested date into PhotoKit's implicit current date.
enum ImportCaptureDate {
    static func parse(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})"#
            + #"(?:\.([0-9]{1,9}))?(Z|([+-])([0-9]{2}):([0-9]{2}))$"#
        let text = value as NSString
        let range = NSRange(location: 0, length: text.length)
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: value, range: range), match.range == range else {
            throw SuwopError("撮影日時の形式が不正です。保存せずに停止しました。")
        }
        func part(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        let numbers = (1 ... 6).compactMap { part($0).flatMap(Int.init) }
        guard numbers.count == 6, numbers[0] > 0, numbers[3] < 24, numbers[4] < 60, numbers[5] < 60 else {
            throw SuwopError("撮影日時の値が不正です。")
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw SuwopError("UTC を確認できません。") }
        calendar.timeZone = utc
        let components = DateComponents(
            year: numbers[0],
            month: numbers[1],
            day: numbers[2],
            hour: numbers[3],
            minute: numbers[4],
            second: numbers[5]
        )
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components
        else { throw SuwopError("撮影日時の暦日が不正です。") }
        let hours = part(10).flatMap(Int.init) ?? 0
        let minutes = part(11).flatMap(Int.init) ?? 0
        guard hours < 24, minutes < 60 else { throw SuwopError("撮影日時の時差が不正です。") }
        let offset = (hours * 3600 + minutes * 60) * (part(9) == "-" ? -1 : 1)
        let fraction = part(7).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(fraction - Double(offset))
    }
}
