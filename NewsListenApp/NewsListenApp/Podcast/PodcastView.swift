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
    /// apiClient は `ContentView` から注入し、init で `StateObject` を一度だけ生成する
    /// （`FeedView` と同様、プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: PodcastViewModel
    /// キャッシュマネージャ。
    private let cacheManager: AudioCacheManager
    /// ネットワーク監視。
    private let networkMonitor: NetworkMonitoring
    /// アプリ全体で共有する設定状態（通知ディープリンクの監視に使う）。
    @EnvironmentObject private var appState: AppState

    /// ビューを生成する。
    /// - Parameters:
    ///   - apiClient: ViewModel に注入する API クライアント。
    ///   - cacheManager: 音声キャッシュマネージャ（既定: `AudioCacheManager()`）。
    ///   - networkMonitor: ネットワーク監視（既定: `NetworkMonitor()`）。
    init(
        apiClient: APIClient,
        cacheManager: AudioCacheManager = AudioCacheManager(),
        networkMonitor: NetworkMonitoring = NetworkMonitor()
    ) {
        _viewModel = StateObject(wrappedValue: PodcastViewModel(apiClient: apiClient, cacheManager: cacheManager, networkMonitor: networkMonitor))
        self.cacheManager = cacheManager
        self.networkMonitor = networkMonitor
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                if viewModel.currentPodcast != nil {
                    AudioPlayerView(vm: viewModel)
                        .transition(.move(edge: .bottom))
                }
            }
            .navigationTitle("Podcast")
            .animation(.spring(), value: viewModel.currentPodcast?.id)
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.loadPodcasts() }
        // タブ離脱時に再生を止め、AVPlayer / TimeObserver を解放する。
        .onDisappear { viewModel.stopPlayback() }
        // 通知タップで指定された Podcast を再生する（ディープリンク・issue #80）。
        // コールドスタート（既に値が入っている）と起動後の両方に対応する。
        .task(id: appState.selectedPodcastId) { await consumeDeepLink() }
    }

    /// 通知ディープリンクで指定された Podcast を再生し、消費後に状態をクリアする。
    private func consumeDeepLink() async {
        guard let id = appState.selectedPodcastId else { return }
        await viewModel.playById(id)
        appState.selectedPodcastId = nil
    }

    /// 読み込み状態・空状態・一覧を出し分ける主コンテンツ。
    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.podcasts.isEmpty {
            ProgressView("読み込み中...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.podcasts.isEmpty {
            ContentUnavailableView(
                "Podcast がありません",
                systemImage: "headphones",
                description: Text("しばらく後に再度確認してください")
            )
        } else {
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
                onDownloadTap: {
                    Task {
                        await viewModel.download(podcast: podcast)
                    }
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                Task {
                    await viewModel.play(podcast: podcast)
                }
            }
            .accessibilityHint("タップで再生を開始します")
        }
        .listStyle(.plain)
        .refreshable { await viewModel.loadPodcasts() }
    }

    /// エラーアラートの表示有無を `errorMessage` の有無に橋渡しする `Binding`。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
