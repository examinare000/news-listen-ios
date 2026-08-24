//
//  PodcastView.swift
//  NewsListenApp
//
//  Podcast タブのルートビュー。一覧表示と、行タップでの再生・プレイヤー表示を担う。
//

import SwiftUI

/// Podcast タブのルートビュー。一覧表示と、行タップでの再生・プレイヤー表示を担う。
struct PodcastView: View {
    /// 一覧取得と再生制御を担う ViewModel。
    ///
    /// タブ間で再生を継続させるため所有は `ContentView`（`@StateObject`）にあり、
    /// 本ビューは参照するだけ（タブ切替で本ビューが消えても再生状態は生きる）。
    @ObservedObject var viewModel: PodcastViewModel
    /// 再生待ちキューのシート表示状態（issue #81）。
    @State private var showQueue = false
    /// アプリ全体で共有する設定状態（ストリーク表示に使う）。
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // オフライン時の事前案内バナー（issue #54）。
                if !viewModel.isOnline {
                    OfflineBanner()
                }
                content
                if viewModel.currentPodcast != nil {
                    AudioPlayerView(vm: viewModel)
                        .transition(.move(edge: .bottom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsScreenBackground()
            .navigationTitle("Podcast")
            .dsStreakToolbar(appState: appState)
            // WHY: value を id ではなく2本の Bool へ分ける（キュー自動遷移で id は変わるが
            //      どちらの Bool も変わらないため、List を巻き込む暗黙アニメーションが消える）。
            //      外側 VStack に置くことで、パネル縮小に伴う List の再レイアウトも同じ
            //      トランザクションで駆動する（Group へ分離すると挿入 transition が不発になる）。
            .animation(.spring(), value: viewModel.currentPodcast != nil)
            .animation(.spring(duration: 0.35), value: viewModel.didFinishCurrentEpisode)
            .toolbar {
                // 再生待ち一覧（キュー）を開く。待機数をバッジ的に併記する。
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showQueue = true } label: {
                        Label("再生待ち\(viewModel.queue.upNext.isEmpty ? "" : "（\(viewModel.queue.upNext.count)）")", systemImage: "list.bullet")
                    }
                    .accessibilityLabel("再生待ちキュー")
                }
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.loadPodcasts() }
        .sheet(isPresented: $showQueue) {
            QueueSheet(viewModel: viewModel)
        }
    }

    /// 読み込み状態・エラー・空状態・一覧を出し分ける主コンテンツ。
    @ViewBuilder
    private var content: some View {
        switch viewModel.displayState {
        case .loading:
            ProgressView("読み込み中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            // ロード失敗時は「本当に空」と区別し、再試行導線を伴うエラー表示にする（issue #53）。
            ContentUnavailableView {
                Label("読み込みに失敗しました", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("再試行") { Task { await viewModel.loadPodcasts() } }
                    .buttonStyle(.borderedProminent)
                    .tint(DSColor.accent)
            }
        case .empty:
            ContentUnavailableView(
                "Podcast がありません",
                systemImage: "headphones",
                description: Text("しばらく後に再度確認してください")
            )
        case .content:
            podcastList
        }
    }

    /// Podcast 一覧の `List`。行タップでその Podcast を再生する。
    private var podcastList: some View {
        List(viewModel.podcasts) { podcast in
            PodcastRowView(
                podcast: podcast,
                isPlaying: viewModel.currentPodcast?.id == podcast.id && viewModel.isPlaying,
                downloadState: viewModel.downloadState(for: podcast.id),
                isOffline: !viewModel.isOnline,
                onDownloadTap: {
                    Task {
                        await viewModel.download(podcast: podcast)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    await viewModel.playNow(podcast)
                }
            }
            .accessibilityHint("タップで再生を開始します")
            // 連続再生の導線（issue #81）: 次に再生 / キューに追加。
            .contextMenu {
                Button {
                    Task { await viewModel.playNext(podcast) }
                } label: {
                    Label("次に再生", systemImage: "text.insert")
                }
                Button {
                    Task { await viewModel.addToQueue(podcast) }
                } label: {
                    Label("キューに追加", systemImage: "text.append")
                }
            }
            .listRowBackground(DSColor.paper)
            .listRowSeparatorTint(DSColor.hairline)
            .listRowInsets(EdgeInsets(top: DSSpacing.xs, leading: DSSpacing.l, bottom: DSSpacing.xs, trailing: DSSpacing.l))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DSColor.paper)
        .refreshable { await viewModel.loadPodcasts() }
    }

    /// エラーアラートの表示有無を橋渡しする `Binding`。
    /// 一覧が空でインラインエラー表示中は二重表示を避けるため、判定は
    /// `viewModel.shouldPresentErrorAlert` に委ねる（issue #58）。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.shouldPresentErrorAlert },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

#if DEBUG
#Preview("Podcast List / Light") {
    PodcastView(viewModel: PreviewSamples.playerViewModel())
        .environmentObject(PreviewSamples.appState())
}

#Preview("Podcast List / Dark") {
    PodcastView(viewModel: PreviewSamples.playerViewModel())
        .environmentObject(PreviewSamples.appState())
        .preferredColorScheme(.dark)
}
#endif
