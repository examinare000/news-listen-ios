//
//  QueueSheet.swift
//  NewsListenApp
//
//  再生待ちキュー（プレイリスト）の確認・並べ替え・削除シート（issue #81）。
//  現在再生中と待機列（upNext）を表示し、待機列はドラッグで並べ替え・スワイプで削除できる。
//

import SwiftUI

/// 再生キューを確認・編集するシート。
struct QueueSheet: View {
    /// 再生キューを保持する ViewModel。
    @ObservedObject var viewModel: PodcastViewModel
    /// シートを閉じるための環境アクション。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // 再生中はミニプレイヤーが開いているときのみ表示する（終端後の残留表示を避ける）。
                if let current = viewModel.nowPlaying()?.queueEntry {
                    Section("再生中") {
                        QueueRow(entry: current)
                    }
                }

                Section("再生待ち") {
                    if viewModel.upNext().isEmpty {
                        Text("キューは空です")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    } else {
                        ForEach(viewModel.upNext()) { entry in
                            QueueRow(entry: entry)
                        }
                        .onDelete { offsets in
                            // 削除でインデックスがずれるため、先に id をスナップショットしてから消す。
                            let ids = offsets.map { viewModel.upNext()[$0].id }
                            ids.forEach { viewModel.removeFromQueue(id: $0) }
                        }
                        .onMove { source, destination in
                            viewModel.moveUpNext(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DSColor.paper)
            .navigationTitle("再生キュー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// キュー内の 1 行（タイトル＝日本語イントロ要約・難易度・長さ）。
private struct QueueRow: View {
    let entry: QueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(entry.introText)
                .font(DSFont.body)
                .foregroundStyle(DSColor.ink)
                .lineLimit(2)
            Text("\(entry.difficulty) · \(formattedDuration(entry.durationSeconds))")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.inkTertiary)
        }
        .listRowBackground(DSColor.paper)
        .accessibilityElement(children: .combine)
    }
}

/// 秒数を `分:秒`（例: `3:05`）の表示用文字列へ整形する。
private func formattedDuration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}
