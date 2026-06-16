//
//  FeedView.swift
//  NewsListenApp
//
//  Feed タブのルートビュー。記事一覧・スワイプ操作（Star/Dismiss）・記事タップでの遷移を担う。
//

import SwiftUI

// URL を sheet(item:) で提示するための Identifiable ラッパー。
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct FeedView: View {
    @EnvironmentObject private var appState: AppState
    // apiClient は ContentView から注入し、init で StateObject を一度だけ生成する
    // （プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: FeedViewModel
    @Environment(\.openURL) private var openURL
    @State private var safariURL: IdentifiableURL?

    init(apiClient: APIClient) {
        _viewModel = StateObject(wrappedValue: FeedViewModel(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.articles.isEmpty {
                    ProgressView("読み込み中...")
                } else if viewModel.articles.isEmpty {
                    ContentUnavailableView(
                        "記事がありません",
                        systemImage: "newspaper",
                        description: Text("しばらく後に再度確認してください")
                    )
                } else {
                    articleList
                }
            }
            .navigationTitle("フィード")
            .toolbar {
                Button {
                    Task { await viewModel.loadFeed() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.loadFeed() }
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    private var articleList: some View {
        List(viewModel.articles) { article in
            ArticleRowView(article: article)
                .contentShape(Rectangle())
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task { await viewModel.dismiss(article: article) }
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await viewModel.star(article: article) }
                    } label: {
                        Label("Star", systemImage: "star.fill")
                    }
                    .tint(.yellow)
                }
                .onTapGesture { open(article) }
        }
        .listStyle(.plain)
        .refreshable { await viewModel.loadFeed() }
    }

    // 記事タップ時は設定（articleOpenMode）に従って開く。
    private func open(_ article: Article) {
        guard let url = URL(string: article.url) else { return }
        switch appState.articleOpenMode {
        case .inApp:
            safariURL = IdentifiableURL(url: url)
        case .external:
            openURL(url)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
