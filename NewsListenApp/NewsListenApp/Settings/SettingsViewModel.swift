//
//  SettingsViewModel.swift
//  NewsListenApp
//
//  Settings タブの状態とロジック。RSS ソースの取得・追加・編集・削除を担う。
//

import Foundation
import Combine

/// Settings タブの状態とロジックを担う ViewModel。RSS ソースの取得・追加・編集・削除を行う。
@MainActor
final class SettingsViewModel: ObservableObject {
    /// 登録済みの RSS ソース一覧。
    @Published var sources: [RssSource] = []
    /// システム提供のおすすめサイト一覧。
    @Published var featuredSites: [FeaturedSite] = []
    /// 読み込み中かどうか。
    @Published var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published var errorMessage: String?
    /// 直近の `loadFeaturedSites()` が失敗したか（issue #164）。
    ///
    /// `featuredSites` は失敗時も空のまま既存仕様（`errorMessage` は汚さずセクション非表示）を
    /// 維持しつつ、設定画面のインライン警告・再試行導線にこのフラグを使う。
    @Published private(set) var featuredSitesLoadFailed = false
    /// Podcast 生成の本日残回数（issue #164 / ADR-061）。未取得・取得失敗時は `nil`。
    @Published private(set) var generationQuota: GenerationQuota?
    /// 直近の `loadGenerationQuota()` が失敗したか。
    @Published private(set) var generationQuotaLoadFailed = false
    /// ダウンロード音声キャッシュの合計サイズ（バイト・issue #52）。未取得時は `0`。
    @Published private(set) var cacheSizeBytes: Int64 = 0

    /// API 通信に使うクライアント。
    ///
    /// `AppState/apiClient` は URL 不正・未設定時に `nil` を返すため optional とする。
    /// `nil` の場合は RSS ソース操作を行わず、難易度・API 設定の編集のみ可能にする
    /// （設定タブからの設定修正の導線を残すため）。
    private let apiClientOverride: APIClient?
    /// 本番では共有状態を正本として API クライアントも AppState から取得する。
    private let appState: AppState?
    private var apiClient: APIClient? { appState?.apiClient ?? apiClientOverride }
    /// ダウンロード音声の保存庫。容量取得・全削除に使う（issue #52）。
    private let library: OfflineLibrary
    /// 「キャッシュ全削除」の窓口。範囲は `OfflineDownloads` の現在主体に従う。
    private let downloads: OfflineDownloads

    /// おすすめサイトをカテゴリでグループ化したもの（表示順で並ぶ）。0件のカテゴリは除外。
    var categorizedFeaturedSites: [(category: FeaturedCategory, sites: [FeaturedSite])] {
        let grouped = FeaturedCategory.groupByCategoryInOrder(featuredSites)
        return FeaturedCategory.allCases
            .compactMap { category in
                let sites = grouped[category] ?? []
                return sites.isEmpty ? nil : (category: category, sites: sites)
            }
    }

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。未設定時は `nil`。
    ///   - library: 保存庫。合成 root が作った 1 個を渡す。
    ///   - downloads: ダウンロード use case。キャッシュの全削除に使う。
    init(
        apiClient: APIClient?,
        library: OfflineLibrary,
        downloads: OfflineDownloads
    ) {
        self.apiClientOverride = apiClient
        self.appState = nil
        self.library = library
        self.downloads = downloads
    }

    /// 共有 AppState を正本として使う本番用 initializer。
    init(
        appState: AppState,
        library: OfflineLibrary,
        downloads: OfflineDownloads
    ) {
        self.apiClientOverride = nil
        self.appState = appState
        self.library = library
        self.downloads = downloads
    }

    /// RSS ソース一覧を取得して `sources` を更新する。失敗時は `errorMessage` に反映する。
    func loadSources() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchSources()
            sources = response.sources
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .settings)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// おすすめサイト一覧を取得して `featuredSites` を更新する。
    ///
    /// 失敗してもおすすめ欄が出ないだけで RSS ソース管理は妨げないため、`errorMessage`（アラート）
    /// には反映しない。代わりに `featuredSitesLoadFailed` を立て、インライン表示 + 再試行に使う
    /// （issue #164・完全サイレントの解消）。
    func loadFeaturedSites() async {
        guard let apiClient else { return }
        do {
            let response = try await apiClient.fetchFeaturedSites()
            featuredSites = response.sites
            featuredSitesLoadFailed = false
        } catch {
            featuredSites = []
            featuredSitesLoadFailed = true
        }
    }

    /// RSS ソースを追加し、サーバが返す最新一覧で `sources` を更新する。
    /// - Parameters:
    ///   - name: ソースの表示名。
    ///   - url: RSS フィードの URL。
    func addSource(name: String, url: String) async {
        guard let apiClient else { return }
        do {
            let response = try await apiClient.addSource(name: name, url: url)
            sources = response.sources
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 既存 RSS ソースの名称・URL を編集し、サーバが返す最新一覧で `sources` を更新する（issue #112）。
    /// 失敗時は `errorMessage` に反映し、`sources` は変更しない。
    /// - Parameters:
    ///   - oldURL: 編集対象を特定する既存の RSS フィード URL。
    ///   - name: 新しい表示名。
    ///   - url: 新しい RSS フィード URL（変更しない場合は `oldURL` と同値）。
    func updateSource(oldURL: String, name: String, url: String) async {
        guard let apiClient else { return }
        do {
            let response = try await apiClient.updateSource(oldURL: oldURL, name: name, url: url)
            sources = response.sources
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 指定 URL の RSS ソースを削除し、一覧から取り除く。失敗時は `errorMessage` に反映する。
    /// - Parameter url: 削除対象ソースの URL。
    func removeSource(url: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.removeSource(url: url)
            sources.removeAll { $0.url == url }
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Podcast 生成の本日残回数を取得する（issue #164 / ADR-061）。
    /// 失敗時は `generationQuota` を `nil` のまま `generationQuotaLoadFailed` を立てる。
    /// 404 時は graceful degradation: セクション非表示（`generationQuotaLoadFailed = false`）。
    func loadGenerationQuota() async {
        guard let apiClient else { return }
        do {
            generationQuota = try await apiClient.fetchGenerationQuota()
            generationQuotaLoadFailed = false
        } catch ApiFailure.notFound(subject: .quota) {
            // 404 = 旧 backend への graceful degradation。セクション非表示（警告なし）
            generationQuota = nil
            generationQuotaLoadFailed = false
        } catch {
            generationQuota = nil
            generationQuotaLoadFailed = true
        }
    }

    // MARK: - ダウンロード音声キャッシュの容量表示・全削除 (issue #52)
    //
    // LRU 等の自動退避は行わない（スコープ外）。容量把握と手動全削除の導線のみ提供する。

    /// ダウンロード音声キャッシュの合計サイズを取得して `cacheSizeBytes` を更新する。
    func loadCacheSize() async {
        cacheSizeBytes = library.usage()
    }

    /// ダウンロード音声キャッシュを全削除する。失敗時は `errorMessage` に反映し、`cacheSizeBytes` は
    /// 実際の残容量を再取得して反映する（削除が一部失敗した場合の不整合表示を避ける）。
    func clearCache() async {
        do {
            try downloads.removeAll()
            errorMessage = nil
        } catch {
            errorMessage = "キャッシュの削除に失敗しました"
        }
        cacheSizeBytes = library.usage()
    }

    // MARK: - 設定の保存の失敗表示

    /// 設定の保存（`PreferencesStore` の command）を実行し、結果を `errorMessage` に反映する。
    /// View が `errorMessage` へ直接書かないための窓口。成功なら `nil`、失敗は error の種類に依らず `failureMessage`。
    /// - Parameters:
    ///   - failureMessage: 失敗時に表示する文言。
    ///   - operation: 保存の実行。
    func savePreference(failureMessage: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = failureMessage
        }
    }
}
