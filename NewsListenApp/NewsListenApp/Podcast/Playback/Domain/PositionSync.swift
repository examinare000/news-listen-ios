//
//  PositionSync.swift
//  NewsListenApp
//
//  端末の位置の記録（時刻つきの位置）の値と、新しさの比較・取り込みの判定・時刻の書式（ADR-109）。
//

import Foundation

struct RecordedPosition: Equatable {
    let seconds: Double
    let recordedAt: Date?
}

/// 端末が記録した位置。主体 × エピソードで最新 1 件を持つ。時刻はミリ秒の整数（ios-dec-136）。
struct PositionRecord: Equatable {
    let subject: SubjectKey
    let episodeId: String
    let seconds: Double
    let recordedAt: Date
    let isSent: Bool

    init(subject: SubjectKey, episodeId: String, seconds: Double, recordedAt: Date, isSent: Bool) {
        self.subject = subject
        self.episodeId = episodeId
        self.seconds = max(0, seconds)
        self.recordedAt = PositionSyncRules.floorToMilliseconds(recordedAt)
        self.isSent = isSent
    }

    func markedSent() -> PositionRecord {
        PositionRecord(subject: subject, episodeId: episodeId, seconds: seconds, recordedAt: recordedAt, isSent: true)
    }
}

enum PositionSyncRules {
    /// 浮動小数の誤差（1 ミリ秒の 1000 分の 1 未満）で、ちょうどのミリ秒を 1 つ下へ切り捨てないための幅。
    private static let millisecondTolerance = 0.001

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let timestampPattern =
        #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"#

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000 + millisecondTolerance).rounded(.down))
    }

    static func floorToMilliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(epochMilliseconds(date)) / 1000)
    }

    /// 時刻の無い値は最も古い。同じ時刻は新しくない（shared-dec-32）。
    static func isNewer(_ lhs: Date?, than rhs: Date?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        return lhs > rhs
    }

    static func shouldAbsorb(_ response: RecordedPosition, over record: PositionRecord?) -> Bool {
        guard let record else { return false }
        return isNewer(response.recordedAt, than: record.recordedAt)
    }

    /// UTC・小数 3 桁・末尾 `Z`。`ISO8601DateFormatter` の小数の扱いには依存しない。
    static func format(_ date: Date) -> String {
        let milliseconds = epochMilliseconds(date)
        let seconds = Int(milliseconds.floorDivided(by: 1000))
        let fraction = Int(milliseconds - Int64(seconds) * 1000)
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: Date(timeIntervalSince1970: Double(seconds)))
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%03ldZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, fraction)
    }

    /// `Z`・`±hh:mm`・小数 0〜9 桁を受ける。小数は 3 桁へ切ってから読む。読めなければ nil。
    static func parse(_ text: String?) -> Date? {
        guard let text,
              let regex = try? NSRegularExpression(pattern: timestampPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        var components = DateComponents()
        components.timeZone = utc.timeZone
        components.year = group(1).flatMap { Int($0) }
        components.month = group(2).flatMap { Int($0) }
        components.day = group(3).flatMap { Int($0) }
        components.hour = group(4).flatMap { Int($0) }
        components.minute = group(5).flatMap { Int($0) }
        components.second = group(6).flatMap { Int($0) }
        guard let base = utc.date(from: components), utc.dateComponents([.day], from: base).day == components.day else {
            return nil
        }
        let fraction = (group(7) ?? "").prefix(3)
        let milliseconds = Int64(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        var offsetSeconds: Int64 = 0
        if let zone = group(8), zone != "Z" {
            let sign: Int64 = zone.hasPrefix("-") ? -1 : 1
            let hours = Int64(zone.dropFirst().prefix(2)) ?? 0
            let minutes = Int64(zone.suffix(2)) ?? 0
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        }
        let epochMilliseconds = (Int64(base.timeIntervalSince1970) - offsetSeconds) * 1000 + milliseconds
        return Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
    }
}

private extension Int64 {
    func floorDivided(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
