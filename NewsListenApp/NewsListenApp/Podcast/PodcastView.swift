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
    /// 再生待ちキューのシート表示状態（issue #81）。
    @State private var showQueue = false

    /// ビューを生成する。
    /// - Parameters:
    ///   - apiClient: ViewModel に注入する API クライアント。
    ///   - cacheManager: 音声キャッシュマネージャ（既定: `AudioCacheManager()`）。
    ///   - networkMonitor: ネットワーク監視（既定: `NetworkMonitor()`）。
    /// - Note: `@MainActor` 化した ``NetworkMonitoring`` の既定値生成を分離文脈で行うため、
    ///   ビューの init も `@MainActor` にする（View 生成は常にメインで行われるため安全）。
    @MainActor
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsScreenBackground()
            .navigationTitle("Podcast")
            .animation(.spring(), value: viewModel.currentPodcast?.id)
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
        // タブ離脱時に再生を止め、AVPlayer / TimeObserver を解放する。
        .onDisappear { viewModel.stopPlayback() }
        .sheet(isPresented: $showQueue) {
            QueueSheet(viewModel: viewModel)
        }
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

    /// エラーアラートの表示有無を `errorMessage` の有無に橋渡しする `Binding`。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

#if DEBUG
#Preview("Podcast List / Light") {
    PodcastView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
}

#Preview("Podcast List / Dark") {
    PodcastView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
        .preferredColorScheme(.dark)
}
#endif
