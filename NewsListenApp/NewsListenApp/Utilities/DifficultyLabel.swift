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
