//
//  GenerationAllowance.swift
//  NewsListenApp
//
//  Podcast 生成の本日の残り回数と、生成上限に達したときの待ちの規則（ios-rule-curation-02・ios-rule-curation-03）。
//

import Foundation

/// 本日の生成の上限・使用量・残り。上限 0 は無制限。負の値は作れない。
struct GenerationAllowance: Equatable {
    let limit: Int
    let used: Int
    let remaining: Int?

    init?(limit: Int, used: Int, remaining: Int?) {
        guard limit >= 0, used >= 0 else { return nil }
        self.limit = limit
        self.used = used
        self.remaining = remaining
    }

    var isUnlimited: Bool { limit == 0 }
}

/// 生成上限に達したあと、次に生成できるまでの待ち（切り上げで丸める）。
enum GenerationLimitWait: Equatable {
    case soon
    case minutes(Int)
    case hours(Int)
}

extension GenerationLimitWait {
    /// 秒数が無い・0 以下なら待ちを示さない。
    init?(retryAfterSeconds seconds: Int?) {
        guard let seconds, seconds > 0 else { return nil }
        let minutes = (seconds + 59) / 60
        if seconds < 60 {
            self = .soon
        } else if minutes < 60 {
            self = .minutes(minutes)
        } else {
            self = .hours((seconds + 3599) / 3600)
        }
    }
}
