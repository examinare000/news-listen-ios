//
//  NowPlayingCenter.swift
//  NewsListenApp
//
//  ロック画面/コントロールセンターの再生情報表示とリモートコマンドを隠す port（CP10）。
//

import Foundation
import os

/// ロック画面のリモートコマンド（MediaPlayer の型を隠した表現）。
enum RemoteCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case skipBackward
    case skipForward
    case changePosition(Double)
    case changeRate(Float)
}

/// リモートコマンドの処理結果。
enum RemoteCommandResult: Equatable {
    case success
    case noSuchContent
    case commandFailed
}

/// 1 回の `registerCommands` に対応する不透明な token。
///
/// 解除処理は、作った adapter（または spy）だけが与える。可変状態は `state` だけで、
/// `OSAllocatedUnfairLock` が守る。`removal` は `let` なので、どのスレッドから `cancel` しても競合しない。
final class RemoteCommandRegistration: @unchecked Sendable {
    private let removal: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(removal: @escaping @Sendable () -> Void) {
        self.removal = removal
    }

    /// 解除済みなら `true`。
    var isCancelled: Bool { state.withLock { $0 } }

    /// `removal` を高々 1 回だけ実行する（判定はロック内、実行はロックの外）。
    func cancel() {
        let shouldRun = state.withLock { cancelled -> Bool in
            if cancelled { return false }
            cancelled = true
            return true
        }
        if shouldRun { removal() }
    }
}

/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` を隠す port。`AppState` / `PodcastViewModel` /
/// `Auth/SubjectCleanup.swift` はこの protocol だけを参照し、`MediaPlayer` を import しない。
protocol NowPlayingCenter {
    /// ロック画面の再生情報を置き換える。
    func update(_ info: [String: Any])
    /// 既存の再生情報が有れば、経過/総時間だけを上書きする（無ければ何もしない）。
    func updateElapsed(_ elapsed: Double, duration: Double)
    /// ロック画面/コントロールセンターの再生情報表示を消す。
    func clear()
    /// リモートコマンドを handler へ配線する。戻り値の token はこの登録分だけを解除する。
    func registerCommands(_ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult) -> RemoteCommandRegistration
    /// `registerCommands` で得た token の登録を外す（冪等）。
    func unregister(_ registration: RemoteCommandRegistration)
}
