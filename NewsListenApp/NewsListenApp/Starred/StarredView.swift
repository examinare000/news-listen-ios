//
//  StarredView.swift
//  NewsListenApp
//
//  スタータブのルートビュー。Star 済み記事の一覧表示と、スワイプによる un-star 導線を担う。
//

import SwiftUI

/// スタータブのルートビュー。Star 済み記事の一覧表示と、スワイプによる un-star 導線を担う。
struct StarredView: View {
    /// アプリ全体で共有する設定状態（記事の開き方〈アプリ内/外部ブラウザ〉の判定に使う）。
    @EnvironmentObject private var appState: AppState
    /// 一覧取得を担う ViewModel。
    ///
    /// apiClient は `ContentView` から注入し、init で `StateObject` を一度だけ生成する
    /// （`FeedView`/`PodcastView` と同様、プレースホルダ生成 + 後差し替えのアンチパターンを避ける）。
    @StateObject private var viewModel: StarredViewModel
    /// 外部 Safari で開くための環境アクション。
    @Environment(\.openURL) private var openURL
    /// アプリ内 Safari で提示中の URL（なければ `nil`）。
    @State private var safariURL: IdentifiableURL?
    /// un-star 確認ダイアログの対象記事（なければダイアログ非表示）。
    @State private var pendingUnstar: Article?

    /// ビューを生成する。
    /// - Parameter apiClient: ViewModel に注入する API クライアント。
    init(apiClient: APIClient) {
        _viewModel = StateObject(wrappedValue: StarredViewModel(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // オフライン時の事前案内バナー。
                if !viewModel.isOnline {
                    OfflineBanner()
                }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsScreenBackground()
            .navigationTitle("スター")
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.loadStarred() }
        .sheet(item: $safariURL) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "スターを解除しますか？",
            isPresented: Binding(
                get: { pendingUnstar != nil },
                set: { isPresented in if !isPresented { pendingUnstar = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnstar
        ) { article in
            // destructive ロールはここ（確定ボタン）にのみ付ける。理由は articleList のスワイプ
            // ボタン側コメントを参照。
            Button("スター解除", role: .destructive) {
                Task { await viewModel.unstar(article) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("この記事から生成されたポッドキャストも削除されます。もう一度スターすると本日の生成回数を消費します。")
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
            // ロード失敗時は「本当に空」と区別し、再試行導線を伴うエラー表示にする（issue #53 と同じ理由）。
            ContentUnavailableView {
                Label("読み込みに失敗しました", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("再試行") { Task { await viewModel.loadStarred() } }
                    .buttonStyle(.borderedProminent)
                    .tint(DSColor.accent)
            }
        case .empty:
            ContentUnavailableView(
                "スターした記事がありません",
                systemImage: "star",
                description: Text("フィードで記事をスターすると表示されます")
            )
        case .content:
            articleList
        }
    }

    /// Star 済み記事一覧の `List`。行タップでその記事を開き、trailing スワイプで un-star 確認ダイアログを出す。
    ///
    /// スワイプアクションは SwiftUI が VoiceOver へカスタムアクションとして自動公開するため、
    /// 追加の a11y 配線は不要（`accessibilityAction` を別途足す必要はない）。
    private var articleList: some View {
        List(viewModel.articles) { article in
            Button {
                open(article)
            } label: {
                ArticleRowView(article: article)
            }
            .buttonStyle(.plain)
            .accessibilityHint("タップで記事を開きます")
            .listRowBackground(DSColor.paper)
            .listRowSeparatorTint(DSColor.hairline)
            .listRowInsets(EdgeInsets(top: DSSpacing.xs, leading: DSSpacing.l, bottom: DSSpacing.xs, trailing: DSSpacing.l))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // このボタンには destructive ロールを付けない（`.tint` のみで警告色を出す）。
                // role: .destructive を付けると、確認ダイアログを出す前にタップ時点（full swipe
                // 時は swipe 完了時点）で行が消えてしまう SwiftUI の既知挙動があるため。
                // destructive ロールは確認ダイアログの確定ボタン側にのみ付ける。
                Button {
                    pendingUnstar = article
                } label: {
                    Label("スター解除", systemImage: "star.slash")
                }
                .tint(DSColor.danger)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DSColor.paper)
        .refreshable { await viewModel.loadStarred() }
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

    /// エラーアラートの表示有無を橋渡しする `Binding`。
    /// 一覧が空でインラインエラー表示中は二重表示を避けるため、判定は
    /// `viewModel.shouldPresentErrorAlert` に委ねる（issue #58 と同じ理由）。
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.shouldPresentErrorAlert },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

#if DEBUG
#Preview("Starred / Light") {
    StarredView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
}

#Preview("Starred / Dark") {
    StarredView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
        .preferredColorScheme(.dark)
}
#endif
