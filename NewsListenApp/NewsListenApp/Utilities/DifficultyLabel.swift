//
//  DifficultyLabel.swift
//  NewsListenApp
//
//  難易度コードを表示用ラベルへ変換する共有ヘルパ。
//  一覧（PodcastRowView）とロック画面（NowPlayingInfo）で同じ表記を使うため一元化する。
//

import Foundation

/// 難易度コード（例: `toeic_900`）を表示用ラベルへ変換する。
enum DifficultyLabel {
    /// 全難易度コードの一覧（表示順）。記事単位 star の contextMenu 等での列挙に使う（issue #163）。
    static let allCodes: [String] = DifficultyLevel.allCases.map(\.code)

    /// 難易度コードを表示用ラベルへ変換する。未知の値はそのまま返す。
    /// - Parameter difficulty: 難易度コード（例: `toeic_900`）。
    static func text(for difficulty: String) -> String {
        switch difficulty {
        case DifficultyLevel.toeic600.code: return "TOEIC 600-"
        case DifficultyLevel.toeic900.code: return "TOEIC 730-900"
        case DifficultyLevel.ielts55.code: return "IELTS 5.5-6.5"
        case DifficultyLevel.ielts7.code: return "IELTS 7.0+"
        case DifficultyLevel.eiken2.code: return "英検2級"
        case DifficultyLevel.eikenP1.code: return "英検準1級"
        default: return difficulty
        }
    }
}
