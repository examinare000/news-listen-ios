//
//  PodcastRowView.swift
//  NewsListenApp
//
//  Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日を表示する。
//

import SwiftUI

/// Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日を表示する。
struct PodcastRowView: View {
    /// 表示する Podcast。
    let podcast: Podcast
    /// この行の Podcast が現在再生中かどうか（アイコン表示の切り替えに使う）。
    let isPlaying: Bool

    var body: some View {
        HStack {
            Image(systemName: isPlaying ? "waveform" : "headphones")
                .font(.title2)
                .foregroundStyle(isPlaying ? .blue : .secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.japaneseIntroText.prefix(60))
                    .font(.headline)
                    .lineLimit(2)
                HStack {
                    Text(difficultyLabel(podcast.difficulty))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                    Text(podcast.formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(podcast.createdAt.prefix(10))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 難易度コードを表示用ラベルへ変換する。未知の値はそのまま返す。
    /// - Parameter difficulty: 難易度コード（例: `toeic_900`）。
    private func difficultyLabel(_ difficulty: String) -> String {
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
