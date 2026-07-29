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
    /// ダウンロード音声キャッシュの容量取得・全削除に使うマネージャ（issue #52）。
    private let cacheManager: AudioCacheManager

    // MARK: - レース対策: 難易度・再生速度同期 (issue #164)

    /// 難易度同期の最新リクエスト ID。stale レスポンスを見分ける。
    private var latestDifficultyRequestId: Int = 0
    /// 再生速度同期の最新リクエスト ID。stale レスポンスを見分ける。
    private var latestPlaybackSpeedRequestId: Int = 0
    /// 週次目標同期の最新リクエスト ID。stale レスポンスを見分ける。
    private var latestWeeklyGoalRequestId: Int = 0

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。未設定時は `nil`。
    ///   - cacheManager: 音声キャッシュの容量取得・全削除に使うマネージャ（既定: `AudioCacheManager()`）。
    init(apiClient: APIClient?, cacheManager: AudioCacheManager = AudioCacheManager()) {
        self.apiClientOverride = apiClient
        self.appState = nil
        self.cacheManager = cacheManager
    }

    /// 共有 AppState を正本として使う本番用 initializer。
    init(appState: AppState, cacheManager: AudioCacheManager = AudioCacheManager()) {
        self.apiClientOverride = nil
        self.appState = appState
        self.cacheManager = cacheManager
    }

    /// RSS ソース一覧を取得して `sources` を更新する。失敗時は `errorMessage` に反映する。
    func loadSources() async {
        guard let apiClient else { return }
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchSources()
            sources = response.sources
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
        } catch APIError.httpError(let statusCode) where statusCode == 404 {
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
        cacheSizeBytes = cacheManager.cacheSize()
    }

    /// ダウンロード音声キャッシュを全削除する。失敗時は `errorMessage` に反映し、`cacheSizeBytes` は
    /// 実際の残容量を再取得して反映する（削除が一部失敗した場合の不整合表示を避ける）。
    func clearCache() async {
        do {
            try cacheManager.clearCache()
            errorMessage = nil
        } catch {
            errorMessage = "キャッシュの削除に失敗しました"
        }
        cacheSizeBytes = cacheManager.cacheSize()
    }

    // MARK: - デフォルト難易度・再生速度のサーバー同期 (issue #164)
    //
    // 値そのものは AppState が保持・UserDefaults 永続化するため、ここではサーバー同期の
    // 成否だけを担う。失敗時は既存の errorBinding アラートで見える化し、呼び出し側（View）が
    // 戻り値を見て UI 値をロールバックできるようにする（無音失敗の解消）。

    /// デフォルト難易度をサーバーへ同期する。
    /// - Parameter value: 新しい既定難易度。
    /// - Returns: 成功したら `true`、失敗したら `false`（`errorMessage` にも反映する）。
    /// 複数リクエストが飛んだ場合、最新のもののみ反映・エラー設定。stale な失敗は無視し
    /// `true` を返してロールバック・エラー表示を抑止する（issue #164）。
    func syncDefaultDifficulty(_ value: String) async -> Bool {
        // リクエスト ID をインクリメント（この値で stale チェック）
        latestDifficultyRequestId += 1
        let requestId = latestDifficultyRequestId

        let result = await syncPreference { apiClient in
            _ = try await apiClient.updatePreferences(defaultDifficulty: value, defaultPlaybackSpeed: nil)
        }

        // stale レスポンス判定: 現在の最新 ID より古い → 無視してロールバック・エラー表示なし
        if requestId != latestDifficultyRequestId { return true }

        return result
    }

    /// デフォルト再生速度をサーバーへ同期する。
    /// - Parameter value: 新しい既定再生速度。
    /// - Returns: 成功したら `true`、失敗したら `false`（`errorMessage` にも反映する）。
    /// 複数リクエストが飛んだ場合、最新のもののみ反映・エラー設定。stale な失敗は無視し
    /// `true` を返してロールバック・エラー表示を抑止する（issue #164）。
    func syncDefaultPlaybackSpeed(_ value: Double) async -> Bool {
        // リクエスト ID をインクリメント（この値で stale チェック）
        latestPlaybackSpeedRequestId += 1
        let requestId = latestPlaybackSpeedRequestId

        let result = await syncPreference { apiClient in
            _ = try await apiClient.updatePreferences(defaultDifficulty: nil, defaultPlaybackSpeed: value)
        }

        // stale レスポンス判定: 現在の最新 ID より古い → 無視してロールバック・エラー表示なし
        if requestId != latestPlaybackSpeedRequestId { return true }

        return result
    }

    /// 週次目標をサーバーへ同期する。許容値は UI と backend 契約の 3 / 5 / 7 / 10 に限定する。
    /// - Parameter value: 新しい週次目標。
    /// - Returns: 成功したら `true`、失敗したら `false`（`errorMessage` にも反映する）。
    /// 複数リクエストが飛んだ場合、最新のもののみ反映・エラー設定。stale な失敗は無視し
    /// `true` を返してロールバック・エラー表示を抑止する（issue #164）。
    func syncWeeklyGoal(_ value: Int) async -> Bool {
        guard [3, 5, 7, 10].contains(value) else {
            errorMessage = "学習目標の値が正しくありません"
            return false
        }
        latestWeeklyGoalRequestId += 1
        let requestId = latestWeeklyGoalRequestId

        guard let apiClient else { return true }
        do {
            _ = try await apiClient.updatePreferences(
                defaultDifficulty: nil,
                defaultPlaybackSpeed: nil,
                weeklyGoalEpisodes: value
            )
            errorMessage = nil
        } catch {
            errorMessage = "学習目標の保存に失敗しました"
            // stale レスポンス判定: 現在の最新 ID より古い → エラー表示を抑止して true を返す
            if requestId != latestWeeklyGoalRequestId { return true }
            return false
        }

        // stale レスポンス判定: 現在の最新 ID より古い → 無視してロールバック・エラー表示なし
        if requestId != latestWeeklyGoalRequestId { return true }
        return true
    }

    /// 設定同期の成否を共通化する内部ヘルパー。apiClient 未設定時は同期対象が無いため成功扱いにする。
    /// stale 判定は呼び出し側で行い、ここでは結果を返すだけ。
    private func syncPreference(_ operation: (APIClient) async throws -> Void) async -> Bool {
        guard let apiClient else { return true }
        do {
            try await operation(apiClient)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "設定の保存に失敗しました"
            return false
        }
    }
}
