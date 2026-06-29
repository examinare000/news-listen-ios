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

    /// おすすめサイト一覧。
    @State private var featuredSites: [FeaturedSite] = []
    /// 既に購読済みのサイト id（ボタン表示の切り替えに使う）。
    @State private var addedIDs: Set<String> = []
    /// 「完了/スキップ」処理中フラグ。
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("気になるサイトを選んで購読しましょう。あとから設定でいつでも追加・削除できます。")
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                }
                Section("おすすめサイト") {
                    ForEach(featuredSites) { site in
                        row(for: site)
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
            guard let apiClient = appState.apiClient else { return }
            featuredSites = (try? await apiClient.fetchFeaturedSites())?.sites ?? []
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
            let added = addedIDs.contains(site.id)
            Button(added ? "購読済み" : "購読") {
                Task { await subscribe(site) }
            }
            .buttonStyle(.borderless)
            .disabled(added)
        }
    }

    /// おすすめサイトを即購読する。成功（および既存重複）で購読済みにマークする。
    private func subscribe(_ site: FeaturedSite) async {
        guard let apiClient = appState.apiClient else { return }
        do {
            _ = try await apiClient.addSource(name: site.name, url: site.url)
            addedIDs.insert(site.id)
        } catch APIError.httpError(let statusCode) where statusCode == 409 {
            // 既に登録済みなら購読済み扱い
            addedIDs.insert(site.id)
        } catch {
            // それ以外の失敗は黙殺（ユーザーは再タップ・後から設定で追加できる）
        }
    }

    /// 完了/スキップ。オンボーディング完了を記録し cover を閉じる。
    private func finish() async {
        finishing = true
        await appState.completeOnboarding()
    }
}
