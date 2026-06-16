//
//  FeedView.swift
//  NewsListenApp
//
//  Feed タブのルートビュー。記事一覧・スワイプ操作（Star/Dismiss）・記事タップでの遷移を担う。
//

import SwiftUI

/// URL を `sheet(item:)` で提示するための `Identifiable` ラッパー。
private struct IdentifiableURL: Identifiable {
    /// 提示対象の URL。
    let url: URL
    /// URL 文字列を一意な識別子とする。
    var id: String { url.absoluteString }
}

/// Feed タブのルートビュー。記事一覧・スワイプ操作（Star/Dismiss）・記事タップでの遷移を担う。
struct FeedView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState
    /// 記事一覧と操作を担う ViewModel。
    ///
    /// apiClient は `ContentView` から注入し、init で `StateObject` を一度だけ生成する
    /// （プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: FeedViewModel
    /// 外部 Safari で開くための環境アクション。
    @Environment(\.openURL) private var openURL
    /// アプリ内 Safari で提示中の URL（なければ `nil`）。
    @State private var safariURL: IdentifiableURL?

    /// ビューを生成する。
    /// - Parameter apiClient: ViewModel に注入する API クライアント。
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

    /// 記事一覧の `List`。左右スワイプで Star/Dismiss、タップで記事を開く。
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

    /// 記事を設定（``AppState/articleOpenMode``）に従って開く。
    /// - Parameter article: タップされた記事。URL が不正なら何もしない。
    private func open(_ article: Article) {
        guard let url = URL(string: article.url) else { return }
        switch appState.articleOpenMode {
        case .inApp:
            safariURL = IdentifiableURL(url: url)
        case .external:
            openURL(url)
        }
    }

    /// エラーアラートの表示有無を `errorMessage` の有無に橋渡しする `Binding`。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
