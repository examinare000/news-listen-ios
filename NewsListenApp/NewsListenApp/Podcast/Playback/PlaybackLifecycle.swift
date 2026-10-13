//
//  PlaybackLifecycle.swift
//  NewsListenApp
//
//  主体離脱（logout・失効）時に再生を止めるための port（ios-slice-auth-01）。
//
//  ios-temp-04（owner: user／導入: ios-slice-auth-01 2026-09-28／削除条件: ios-slice-playback-03 で `PlaybackCoordinator` が
//  この port の実装を引き継いだ時点。コードの物理削除は ios-slice-playback-04）: 本 slice では
//  `PodcastViewModel` が暫定的にこの port を実装する（`PodcastViewModel.swift` を参照）。
//

import Foundation

/// 主体離脱時の再生停止のみを表す port。`SubjectCleanup` はこの protocol だけを参照し、
/// `PodcastViewModel` 型を直接参照しない（境界の leakage 検査: grep oracle O-6）。
@MainActor
protocol PlaybackLifecycle: AnyObject {
    /// 主体離脱時に再生を止める。位置同期は送らない（C1）。
    func stopForLogout()
}
