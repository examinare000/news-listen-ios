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
    static let allCodes: [String] = ["toeic_600", "toeic_900", "ielts_55", "ielts_7", "eiken_2", "eiken_p1"]

    /// 難易度コードを表示用ラベルへ変換する。未知の値はそのまま返す。
    /// - Parameter difficulty: 難易度コード（例: `toeic_900`）。
    static func text(for difficulty: String) -> String {
        switch difficulty {
        case "toeic_600": return "TOEIC 600-"
        case "toeic_900": return "TOEIC 730-900"
        case "ielts_55": return "IELTS 5.5-6.5"
        case "ielts_7": return "IELTS 7.0+"
        case "eiken_2": return "英検2級"
        case "eiken_p1": return "英検準1級"
        default: return difficulty
        }
    }
}
