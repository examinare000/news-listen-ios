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
    /// アプリのライフサイクル状態（バックグラウンド遷移で保留操作を確定するため）。
    @Environment(\.scenePhase) private var scenePhase
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsScreenBackground()
            .navigationTitle("フィード")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.isSelectionMode.toggle()
                        if !viewModel.isSelectionMode {
                            viewModel.selectedIds.removeAll()
                        }
                    } label: {
                        Image(systemName: viewModel.isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .accessibilityLabel(viewModel.isSelectionMode ? "選択モード: オン" : "選択モード: オフ")
                    .accessibilityHint("複数の記事を選択できます")

                    Button {
                        Task { await viewModel.loadFeed() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("フィード更新")
                    .accessibilityHint("最新の記事を取得します")
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
        // バックグラウンド遷移時に保留中の Star/Dismiss を確定送信する（取りこぼし防止・issue #111）。
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                Task { await viewModel.commitPending() }
            }
        }
    }

    /// 記事一覧。通常時はジェスチャ対応カード（右スワイプ Star / 左スワイプ Dismiss /
    /// タップ展開 / ダブルタップでソース表示）、選択モードでは選択行を表示する（issue #111）。
    private var articleList: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.articles) { article in
                        row(for: article)
                        // 末尾記事の後ろには区切り線を出さない。
                        if article.id != viewModel.articles.last?.id {
                            Divider().overlay(DSColor.hairline)
                        }
                    }
                }
            }
            .background(DSColor.paper)
            .refreshable { await viewModel.loadFeed() }
            // 画面離脱時は保留中の Star/Dismiss を確定送信する（取り消し猶予の終了）。
            .onDisappear { Task { await viewModel.commitPending() } }

            VStack(spacing: DSSpacing.s) {
                // 誤操作の取り消し導線（保留中のみ表示・一定時間で自動確定）。
                if let pending = viewModel.pendingAction {
                    undoToast(pending)
                }
                if viewModel.isSelectionMode && !viewModel.selectedIds.isEmpty {
                    bulkStarButton
                }
            }
        }
    }

    /// 1 行の表示。選択モードでは選択行、通常時はスワイプ対応カード。
    @ViewBuilder
    private func row(for article: Article) -> some View {
        if viewModel.isSelectionMode {
            HStack(spacing: DSSpacing.m) {
                Image(systemName: viewModel.selectedIds.contains(article.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewModel.selectedIds.contains(article.id) ? DSColor.accent : DSColor.inkTertiary)
                ArticleRowView(article: article)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.l)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.toggleSelection(article.id) }
            .accessibilityHint("タップで選択を切り替えます")
        } else {
            SwipeableArticleCard(
                article: article,
                isExpanded: viewModel.expandedId == article.id,
                onTap: { viewModel.toggleExpand(article.id) },
                onDoubleTap: { open(article) },
                onStar: { Task { await viewModel.star(article: article) } },
                onDismiss: { Task { await viewModel.dismiss(article: article) } }
            )
        }
    }

    /// 取り消しトースト。表示中に一定時間が経過したら自動で確定送信する。
    private func undoToast(_ pending: PendingArticleAction) -> some View {
        HStack(spacing: DSSpacing.m) {
            Text(pending.message)
                .font(DSFont.body)
                .foregroundStyle(DSColor.onAccent)
            Spacer(minLength: 0)
            Button("取り消す") { viewModel.undoLast() }
                .font(DSFont.body.weight(.semibold))
                .foregroundStyle(DSColor.star)
        }
        .padding(.horizontal, DSSpacing.l)   // カプセル内側の余白
        .padding(.vertical, DSSpacing.m)
        .background(DSColor.ink)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
        .padding(.horizontal, DSSpacing.l)   // 画面端からの外側マージン
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pending.message)
        .accessibilityHint("取り消すには取り消すボタンを押します")
        // 4 秒後に自動確定。取り消し（pendingAction 解除）でこのビューが消えると task は中断される。
        .task {
            try? await Task.sleep(for: .seconds(4))
            await viewModel.commitPending()
        }
    }

    /// 選択中の記事を一括 Star するボタン。
    private var bulkStarButton: some View {
        Button(action: { Task { await viewModel.bulkStar() } }) {
            Text("\(viewModel.selectedIds.count)件を一括スター")
                .font(DSFont.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpacing.m)
                .foregroundStyle(DSColor.onAccent)
                .background(DSColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .padding(DSSpacing.l)
        .accessibilityLabel("選択中の記事を一括スター")
        .accessibilityValue("\(viewModel.selectedIds.count)件")
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

#if DEBUG
#Preview("Feed / Light") {
    FeedView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
}

#Preview("Feed / Dark") {
    FeedView(apiClient: PreviewSamples.apiClient())
        .environmentObject(PreviewSamples.appState())
        .preferredColorScheme(.dark)
}
#endif
