//
//  OnboardingSourcesViewModel.swift
//  NewsListenApp
//
//  初回オンボーディング「おすすめサイト追加」ステップの状態とロジックを担う（issue #164）。
//  従来 View に直書きされ、取得/購読の失敗が完全にサイレントだった箇所を切り出し、
//  失敗を可視化できるようにする。
//

import Combine
import Foundation

/// おすすめサイト追加ステップの状態と操作を担う ViewModel。
@MainActor
final class OnboardingSourcesViewModel: ObservableObject {
    /// おすすめサイトをカテゴリでグループ化したもの（表示順で並ぶ）。0件のカテゴリは除外。
    @Published private(set) var categorizedSites: [(category: FeaturedCategory, sites: [FeaturedSiteCard])] = []
    /// 既に購読済みのサイト id（ボタン表示の切り替えに使う）。
    @Published private(set) var addedIDs: Set<String> = []
    /// おすすめサイト取得の直近のエラーメッセージ（なければ `nil`）。
    @Published private(set) var loadErrorMessage: String?
    /// 購読操作の直近のエラーメッセージ（なければ `nil`）。
    @Published private(set) var subscribeErrorMessage: String?
    /// おすすめサイト取得中かどうか。
    @Published private(set) var isLoading = false

    private let subscriptions: SourceSubscriptions
    private let onboarding: OnboardingProgress

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - sources: おすすめサイトの取得・購読を担う application。
    ///   - onboarding: 完了の記録を担う application。
    init(sources: SourceSubscriptions, onboarding: OnboardingProgress) {
        self.subscriptions = sources
        self.onboarding = onboarding
    }

    /// おすすめサイト一覧を取得する。失敗時は `loadErrorMessage` に反映する。
    func loadFeaturedSites() async {
        isLoading = true
        loadErrorMessage = nil
        do {
            categorizedSites = try await subscriptions.featured()
        } catch {
            loadErrorMessage = "おすすめサイトの取得に失敗しました"
        }
        isLoading = false
    }

    /// おすすめサイトを即購読する。成功（および既存重複の 409）で購読済みにマークする。
    /// - Parameter site: 購読対象のおすすめサイト。
    func subscribe(_ site: FeaturedSiteCard) async {
        subscribeErrorMessage = nil
        do {
            try await subscriptions.subscribe(site)
            addedIDs.insert(site.id)
        } catch {
            subscribeErrorMessage = "購読に失敗しました。もう一度お試しください。"
        }
    }

    /// 完了・スキップ。完了を記録し、cover を閉じる状態にする。
    func finish() async {
        await onboarding.complete()
    }
}
