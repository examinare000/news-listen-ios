//
//  PodcastRowView.swift
//  NewsListenApp
//
//  Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日を表示する。
//

import SwiftUI

/// Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日・ダウンロード状態を表示する。
struct PodcastRowView: View {
    /// 表示する Podcast。
    let podcast: Podcast
    /// この行の Podcast が現在再生中かどうか（アイコン表示の切り替えに使う）。
    let isPlaying: Bool
    /// ダウンロード状態（既定: notDownloaded）。
    let downloadState: DownloadState
    /// ダウンロードボタンタップハンドラ（オプション）。
    let onDownloadTap: (() -> Void)?
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    init(
        podcast: Podcast,
        isPlaying: Bool,
        downloadState: DownloadState = .notDownloaded,
        onDownloadTap: (() -> Void)? = nil
    ) {
        self.podcast = podcast
        self.isPlaying = isPlaying
        self.downloadState = downloadState
        self.onDownloadTap = onDownloadTap
    }

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
                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // ダウンロード状態ボタン
            downloadButton
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Podcast: \(String(podcast.japaneseIntroText.prefix(60)))")
        .accessibilityValue("難易度: \(difficultyLabel(podcast.difficulty))、長さ: \(podcast.formattedDuration)、作成日: \(formattedDate)" + (isPlaying ? "、再生中" : ""))
        .accessibilityHint("タップで再生を開始します")
    }

    /// timeFormat 設定に応じた日付表記を返す。
    private var formattedDate: String {
        if appState.timeFormat == "relative" {
            return RelativeTimeFormatter.format(podcast.createdAt)
        } else {
            return String(podcast.createdAt.prefix(10))
        }
    }

    /// ダウンロード状態に応じたボタンを返す。
    @ViewBuilder
    private var downloadButton: some View {
        switch downloadState {
        case .notDownloaded:
            Button(action: { onDownloadTap?() }) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .accessibilityLabel("ダウンロード")
            .accessibilityHint("Podcast をダウンロードします")
        case .downloading:
            ProgressView()
                .scaleEffect(0.8, anchor: .center)
                .accessibilityLabel("ダウンロード中")
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("ダウンロード済み")
        }
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
