//
//  CleanupIncomplete.swift
//  NewsListenApp
//
//  主体離脱の後始末が一部失敗したことを表す値。
//

import Foundation

/// `SubjectCleanup.run()` の中で失敗しうる手順。
enum SubjectCleanupFailedPart: Equatable {
    /// 音声キャッシュ削除（`clearOfflineLibrary`）の失敗。
    case offlineLibrary
}

/// 主体離脱の後始末が一部失敗したことを表す。遷移自体は完了している（shared-dec-28）。
struct CleanupIncomplete: Equatable {
    /// 失敗した手順の一覧。
    let failedParts: [SubjectCleanupFailedPart]
}
