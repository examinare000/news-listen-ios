//
//  SubjectCleanup.swift
//  NewsListenApp
//
//  主体離脱（logout・失効・主体の直接交代）の事後条件を実行する（ios-slice-auth-01 / ios-contract-21 / spec §3.2）。
//  5 手順を独立に試行し、失敗した手順だけを `CleanupIncomplete` に集める
//  （消去失敗があっても認証状態の遷移自体は止めない。shared-dec-28「待たない」）。
//

import Foundation

/// 主体離脱の後始末を実行する（再生停止 → ロック画面クリア → 主体依存設定の既定化 → ダウンロードの cancel → 離脱主体の音声キャッシュ削除）。
///
/// `AppState` は再生ドメインの具象実装を直接参照せず、`PlaybackLifecycle` /
/// `NowPlayingCenter` の port とクロージャだけを介して後始末を行う（leakage 検査: grep oracle O-6）。
@MainActor
struct SubjectCleanup {
    /// 再生停止 port（未登録なら `nil`。未登録は失敗として扱わない: ios-contract-21.6）。
    let playbackLifecycle: PlaybackLifecycle?
    /// ロック画面/コントロールセンターの表示クリア port。
    let nowPlayingCenter: NowPlayingCenter
    /// 主体依存設定（AppState のメモリ値 + registry の subjectScoped key）を既定へ戻す。
    let clearSubjectPreferences: () -> Void
    /// 離脱主体の音声キャッシュを削除する（失敗しうる唯一の手順）。
    let clearOfflineLibrary: (SubjectKey?) throws -> Void
    /// 実行中のダウンロードを cancel する（完了は待たない）。
    let cancelDownloads: () -> Void

    /// 5 手順を順に独立実行する。`@MainActor` の同期処理のため、途中に suspension point は無い。
    /// - Returns: 全手順成功なら `nil`。1 つ以上失敗したら `CleanupIncomplete`。
    func run(departing subject: SubjectKey?) -> CleanupIncomplete? {
        playbackLifecycle?.stopForLogout()
        nowPlayingCenter.clear()
        clearSubjectPreferences()
        cancelDownloads()

        var failedParts: [SubjectCleanupFailedPart] = []
        do {
            try clearOfflineLibrary(subject)
        } catch {
            failedParts.append(.offlineLibrary)
        }

        return failedParts.isEmpty ? nil : CleanupIncomplete(failedParts: failedParts)
    }
}
