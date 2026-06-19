//
//  SettingsViewModel.swift
//  NewsListenApp
//
//  Settings タブの状態とロジック。RSS ソースの取得・追加・削除を担う。
//

import Foundation
import Combine

/// Settings タブの状態とロジックを担う ViewModel。RSS ソースの取得・追加・削除を行う。
@MainActor
final class SettingsViewModel: ObservableObject {
    /// 登録済みの RSS ソース一覧。
    @Published var sources: [RssSource] = []
    /// 読み込み中かどうか。
    @Published var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published var errorMessage: String?

    /// API 通信に使うクライアント。
    ///
    /// `AppState/apiClient` は URL 不正・未設定時に `nil` を返すため optional とする。
    /// `nil` の場合は RSS ソース操作を行わず、難易度・API 設定の編集のみ可能にする
    /// （設定タブからの設定修正の導線を残すため）。
    private let apiClient: APIClient?

    /// ViewModel を生成する。
    /// - Parameter apiClient: API 通信に使うクライアント。未設定時は `nil`。
    init(apiClient: APIClient?) {
        self.apiClient = apiClient
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
}
