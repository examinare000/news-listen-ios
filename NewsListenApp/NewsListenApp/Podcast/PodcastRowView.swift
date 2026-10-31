//
//  PodcastRowView.swift
//  NewsListenApp
//
//  Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日を表示する。
//

import SwiftUI

/// Podcast 一覧の各行。再生状態・イントロ要約・難易度・長さ・作成日・ダウンロード状態を表示する。
struct PodcastRowView: View {
    /// 表示する行。
    let row: EpisodeRow
    /// この行の Podcast が現在再生中かどうか（アイコン表示の切り替えに使う）。
    let isPlaying: Bool
    /// ダウンロード状態（既定: notDownloaded）。
    let downloadState: DownloadState
    /// 現在オフラインかどうか（既定: false）。オフライン時、再生不可な行を視覚的に区別する（issue #54）。
    let isOffline: Bool
    /// ダウンロードボタンタップハンドラ（オプション）。
    let onDownloadTap: (() -> Void)?
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    init(
        row: EpisodeRow,
        isPlaying: Bool,
        downloadState: DownloadState = .notDownloaded,
        isOffline: Bool = false,
        onDownloadTap: (() -> Void)? = nil
    ) {
        self.row = row
        self.isPlaying = isPlaying
        self.downloadState = downloadState
        self.isOffline = isOffline
        self.onDownloadTap = onDownloadTap
    }

    /// オフライン時に再生不可な行を、既存の downloadState 表示のまま淡く沈めて区別する（issue #54）。
    /// 大掛かりな UI 刷新を避けるため opacity のみの最小実装。
    private var rowOpacity: Double {
        (isOffline && !PodcastViewModel.isPlayableWhileOffline(downloadState: downloadState)) ? 0.4 : 1.0
    }

    var body: some View {
        HStack(spacing: DSSpacing.m) {
            Image(systemName: isPlaying ? "waveform" : "headphones")
                .font(.title2)
                .foregroundStyle(isPlaying ? DSColor.accent : DSColor.inkTertiary)
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: DSSpacing.s) {
                Text(String(row.title.prefix(60)))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.ink)
                    .lineLimit(2)
                HStack(spacing: DSSpacing.s) {
                    DSBadge(difficultyLabel(row.difficulty))
                    Text(Self.durationText(seconds: row.durationSeconds))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.inkSecondary)
                    statusBadge
                    Spacer()
                    Text(formattedDate)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.inkSecondary)
                }
            }

            // ダウンロード状態ボタン
            downloadButton
        }
        .padding(.vertical, DSSpacing.s)
        .opacity(rowOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Podcast: \(String(row.title.prefix(60)))")
        .accessibilityValue("難易度: \(difficultyLabel(row.difficulty))、長さ: \(Self.durationText(seconds: row.durationSeconds))、作成日: \(formattedDate)"
            + (isPlaying ? "、再生中" : "")
            + (rowOpacity < 1.0 ? "、オフラインのため再生不可" : ""))
        .accessibilityHint("タップで再生を開始します")
    }

    /// timeFormat 設定に応じた日付表記を返す。
    private var formattedDate: String {
        if appState.timeFormat == "relative" {
            return RelativeTimeFormatter.format(row.createdAt)
        } else {
            return String(row.createdAt.prefix(10))
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
                    .foregroundStyle(DSColor.accent)
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
                .foregroundStyle(DSColor.success)
                .accessibilityLabel("ダウンロード済み")
        }
    }

    /// Podcast 生成ステータスを表示するバッジ。
    @ViewBuilder
    private var statusBadge: some View {
        switch row.badge {
        case .generating:
            DSBadge("生成中", systemImage: "hourglass", tint: DSColor.accent)
                .accessibilityLabel("生成中")
        case .failed(let detail):
            DSBadge("失敗", systemImage: "exclamationmark.triangle.fill", tint: DSColor.danger)
                .accessibilityLabel("生成失敗")
                .accessibilityValue(detail)
        case .none:
            EmptyView()
        }
    }

    /// 秒数を `分:秒`（例: `3:05`）の表示用文字列に整形する。
    nonisolated static func durationText(seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 難易度コードを表示用ラベルへ変換する。共有ヘルパ ``DifficultyLabel`` へ委譲する。
    /// - Parameter difficulty: 難易度コード（例: `toeic_900`）。
    private func difficultyLabel(_ difficulty: String) -> String {
        DifficultyLabel.text(for: difficulty)
    }
}

#if DEBUG
private struct PodcastRowGallery: View {
    private static let playableRow = EpisodeRow(
        episodeId: "p1",
        title: "米連邦準備制度が利上げを見送り、英国経済が予想外の回復を見せた。",
        difficulty: "toeic_900",
        durationSeconds: 247,
        createdAt: "2026-06-29T07:00:00Z",
        badge: .none)
    private static let generatingRow = EpisodeRow(
        episodeId: "p2",
        title: "AI半導体の需要が供給を上回り、関連銘柄が上昇しています。",
        difficulty: "toeic_600",
        durationSeconds: 188,
        createdAt: "2026-06-28T22:30:00Z",
        badge: .generating)
    private static let failedRow = EpisodeRow(
        episodeId: "p3",
        title: "気候サミットがメタン削減の新たな誓約とともに閉幕しました。",
        difficulty: "eiken_2",
        durationSeconds: 0,
        createdAt: "2026-06-28T19:00:00Z",
        badge: .failed(detail: "音声生成に失敗しました"))

    var body: some View {
        List {
            PodcastRowView(row: Self.playableRow, isPlaying: true, downloadState: .downloaded)
            PodcastRowView(row: Self.generatingRow, isPlaying: false, downloadState: .downloading)
            PodcastRowView(row: Self.failedRow, isPlaying: false, downloadState: .notDownloaded, onDownloadTap: {})
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DSColor.paper)
        .environmentObject(PreviewSamples.appState())
    }
}

#Preview("PodcastRow / Light") { PodcastRowGallery() }
#Preview("PodcastRow / Dark") { PodcastRowGallery().preferredColorScheme(.dark) }
#endif
