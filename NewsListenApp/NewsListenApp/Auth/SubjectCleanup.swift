//
//  SubjectCleanup.swift
//  NewsListenApp
//
//  主体離脱（logout・失効の両方）の事後条件を実行する（I-S2 / CI-T15 / spec §3.2）。
//  4 手順を独立に試行し、失敗した手順だけを `CleanupIncomplete` に集める
//  （消去失敗があっても認証状態の遷移自体は止めない。SG-X3「待たない」）。
//

import Foundation

/// `SubjectCleanup.run()` の中で失敗しうる手順。
enum SubjectCleanupFailedPart: Equatable {
    /// 音声キャッシュ削除（`clearOfflineLibrary`）の失敗。
    case offlineLibrary
}

/// 主体離脱の後始末が一部失敗したことを表す。遷移自体は完了している（SG-X3）。
struct CleanupIncomplete: Equatable {
    /// 失敗した手順の一覧。
    let failedParts: [SubjectCleanupFailedPart]
}

/// 主体離脱の後始末を実行する（spec §3.2 の手順 1〜4）。
///
/// `AppState` は再生ドメインの具象実装を直接参照せず、`PlaybackLifecycle` /
/// `NowPlayingCenter` の port とクロージャだけを介して後始末を行う（leakage 検査: grep oracle O-6）。
@MainActor
struct SubjectCleanup {
    /// 再生停止 port（未登録なら `nil`。未登録は失敗として扱わない: CI-T15.6）。
    let playbackLifecycle: PlaybackLifecycle?
    /// ロック画面/コントロールセンターの表示クリア port。
    let nowPlayingCenter: NowPlayingCenter
    /// 主体依存設定（AppState のメモリ値 + registry の subjectScoped key）を既定へ戻す。
    let clearSubjectPreferences: () -> Void
    /// 音声キャッシュを削除する（失敗しうる唯一の手順）。
    let clearOfflineLibrary: () throws -> Void

    /// 4 手順を順に独立実行する。`@MainActor` の同期処理のため、途中に suspension point は無い。
    /// - Returns: 全手順成功なら `nil`。1 つ以上失敗したら `CleanupIncomplete`。
    func run() -> CleanupIncomplete? {
        playbackLifecycle?.stopForLogout()
        nowPlayingCenter.clear()
        clearSubjectPreferences()

        var failedParts: [SubjectCleanupFailedPart] = []
        do {
            try clearOfflineLibrary()
        } catch {
            failedParts.append(.offlineLibrary)
        }

        return failedParts.isEmpty ? nil : CleanupIncomplete(failedParts: failedParts)
    }
}
