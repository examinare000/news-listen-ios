//
//  OnboardingSourcesView.swift
//  NewsListenApp
//
//  初回ログイン時の「おすすめサイト追加」ステップ。API 設定完了後、まだオンボーディング
//  未完了のユーザーにのみ fullScreenCover で表示される（出し分けは ContentView）。
//

import SwiftUI

/// 初回オンボーディングのおすすめサイト追加ステップ。
///
/// おすすめサイトをワンクリックで即購読でき、「完了」/「スキップ」で
/// ``AppState/completeOnboarding()`` を呼んでフィードへ進む。
struct OnboardingSourcesView: View {
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState
    /// おすすめサイト取得・購読を担う ViewModel（issue #164・SettingsView と同様の流儀）。
    @StateObject private var viewModel: OnboardingSourcesViewModel

    /// 「完了/スキップ」処理中フラグ。
    @State private var finishing = false

    /// ビューを生成する。
    /// - Parameter apiClient: ViewModel に注入する API クライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        _viewModel = StateObject(wrappedValue: OnboardingSourcesViewModel(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("気になるサイトを選んで購読しましょう。あとから設定でいつでも追加・削除できます。")
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                }
                Section("おすすめサイト") {
                    ForEach(viewModel.featuredSites) { site in
                        row(for: site)
                    }
                    // おすすめサイト取得の失敗を可視化する（issue #164・完全サイレントの解消）。
                    // オンボーディング完走は阻害しないため、失敗時も「完了/スキップ」は有効なまま。
                    if let error = viewModel.loadErrorMessage {
                        HStack {
                            Text(error).foregroundStyle(DSColor.danger).font(DSFont.footnote)
                            Spacer()
                            Button("再試行") { Task { await viewModel.loadFeaturedSites() } }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let error = viewModel.subscribeErrorMessage {
                        Text(error).foregroundStyle(DSColor.danger).font(DSFont.footnote)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.paper.ignoresSafeArea())
            .navigationTitle("おすすめサイト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("スキップ") { Task { await finish() } }
                        .disabled(finishing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { Task { await finish() } }
                        .disabled(finishing)
                }
            }
        }
        .task {
            await viewModel.loadFeaturedSites()
        }
    }

    /// おすすめサイト1行。サムネイル + 名前/説明 + 購読ボタン。
    @ViewBuilder
    private func row(for site: FeaturedSite) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: site.thumbnailURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "globe").foregroundStyle(DSColor.inkTertiary)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(DSFont.headline).foregroundStyle(DSColor.ink)
                if let description = site.description {
                    Text(description).font(DSFont.caption).foregroundStyle(DSColor.inkSecondary)
                }
            }
            Spacer()
            let added = viewModel.addedIDs.contains(site.id)
            Button(added ? "購読済み" : "購読") {
                Task { await viewModel.subscribe(site) }
            }
            .buttonStyle(.borderless)
            .disabled(added)
        }
    }

    /// 完了/スキップ。オンボーディング完了を記録し cover を閉じる。
    private func finish() async {
        finishing = true
        await appState.completeOnboarding()
    }
}
