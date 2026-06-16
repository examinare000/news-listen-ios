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

    /// ビューを生成する。
    /// - Parameter apiClient: ViewModel に注入する API クライアント。
    init(apiClient: APIClient) {
        _viewModel = StateObject(wrappedValue: PodcastViewModel(apiClient: apiClient))
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
                isPlaying: viewModel.currentPodcast?.id == podcast.id && viewModel.isPlaying
            )
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.play(podcast: podcast)
            }
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
