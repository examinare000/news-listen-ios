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
    /// おすすめサイト一覧。
    @Published private(set) var featuredSites: [FeaturedSite] = []
    /// 既に購読済みのサイト id（ボタン表示の切り替えに使う）。
    @Published private(set) var addedIDs: Set<String> = []
    /// おすすめサイト取得の直近のエラーメッセージ（なければ `nil`）。
    @Published var loadErrorMessage: String?
    /// 購読操作の直近のエラーメッセージ（なければ `nil`）。
    @Published var subscribeErrorMessage: String?
    /// おすすめサイト取得中かどうか。
    @Published private(set) var isLoading = false

    private let apiClient: APIClient?

    /// ViewModel を生成する。
    /// - Parameter apiClient: API 通信に使うクライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    /// おすすめサイト一覧を取得する。失敗時は `loadErrorMessage` に反映する。
    func loadFeaturedSites() async {
        guard let apiClient else { return }
        isLoading = true
        loadErrorMessage = nil
        do {
            featuredSites = try await apiClient.fetchFeaturedSites().sites
        } catch {
            loadErrorMessage = "おすすめサイトの取得に失敗しました"
        }
        isLoading = false
    }

    /// おすすめサイトを即購読する。成功（および既存重複の 409）で購読済みにマークする。
    /// - Parameter site: 購読対象のおすすめサイト。
    func subscribe(_ site: FeaturedSite) async {
        guard let apiClient else { return }
        subscribeErrorMessage = nil
        do {
            _ = try await apiClient.addSource(name: site.name, url: site.url)
            addedIDs.insert(site.id)
        } catch APIError.httpError(let statusCode) where statusCode == 409 {
            // 既に登録済みなら購読済み扱い（ユーザーからは成功と見分けがつかない）。
            addedIDs.insert(site.id)
        } catch {
            subscribeErrorMessage = "購読に失敗しました。もう一度お試しください。"
        }
    }
}
