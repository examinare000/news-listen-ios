//
//  PlaybackLifecycle.swift
//  NewsListenApp
//
//  主体離脱（logout・失効）時に再生を止めるための port（ios-slice-auth-01）。
//
//  この port は `PlaybackCoordinator` が実装する。`PodcastViewModel` は `stopForLogout()` を中継するだけで、準拠しない。
//

import Foundation

/// 主体離脱時の再生停止のみを表す port。`SubjectCleanup` はこの protocol だけを参照し、
/// `PodcastViewModel` 型を直接参照しない（境界の leakage 検査: grep oracle O-6）。
@MainActor
protocol PlaybackLifecycle: AnyObject {
    /// 主体離脱時に再生を止める。位置同期は送らない（C1）。
    func stopForLogout()
}
