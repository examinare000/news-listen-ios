//
//  DifficultyLevel.swift
//  NewsListenApp
//
//  Podcast の難易度の値域（6 値）と既定値の正本。コードの literal はここだけに置く（ios-rule-prefs-01）。
//

import Foundation

/// 難易度。生成は `init?(code:)` と `private init(checked:)` だけで、値域の外は作れない。
struct DifficultyLevel: Equatable, Hashable {
    let code: String

    /// 6 値のどれかでなければ nil。
    init?(code: String) {
        guard let level = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = level
    }

    private init(checked code: String) {
        self.code = code
    }

    static let toeic600 = DifficultyLevel(checked: "toeic_600")
    static let toeic900 = DifficultyLevel(checked: "toeic_900")
    static let ielts55 = DifficultyLevel(checked: "ielts_55")
    static let ielts7 = DifficultyLevel(checked: "ielts_7")
    static let eiken2 = DifficultyLevel(checked: "eiken_2")
    static let eikenP1 = DifficultyLevel(checked: "eiken_p1")

    /// 表示順。
    static let allCases: [DifficultyLevel] = [toeic600, toeic900, ielts55, ielts7, eiken2, eikenP1]

    static let `default`: DifficultyLevel = toeic600
}
