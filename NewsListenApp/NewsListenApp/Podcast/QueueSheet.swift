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
                if viewModel.currentPodcast != nil, let current = viewModel.queue.current {
                    Section("再生中") {
                        QueueRow(podcast: current)
                    }
                }

                Section("再生待ち") {
                    if viewModel.queue.upNext.isEmpty {
                        Text("キューは空です")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    } else {
                        ForEach(viewModel.queue.upNext) { podcast in
                            QueueRow(podcast: podcast)
                        }
                        .onDelete { offsets in
                            // 削除でインデックスがずれるため、先に id をスナップショットしてから消す。
                            let ids = offsets.map { viewModel.queue.upNext[$0].id }
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
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(podcast.japaneseIntroText)
                .font(DSFont.body)
                .foregroundStyle(DSColor.ink)
                .lineLimit(2)
            Text("\(podcast.difficulty) · \(podcast.formattedDuration)")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.inkTertiary)
        }
        .listRowBackground(DSColor.paper)
        .accessibilityElement(children: .combine)
    }
}
