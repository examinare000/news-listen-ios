//
//  PlayerPresentation.swift
//  NewsListenApp
//
//  プレイヤー UI の表示形態。ミニプレイヤーは全タブ共通の下部バー、
//  フルプレイヤーはグローバルシートとして表示する。
//

/// プレイヤー UI の表示形態。
///
/// `hidden` は未再生（初回 play まで）。一度再生すると `mini` / `expanded` の間を
/// 行き来し、`hidden` へは戻らない（キュー終端でも語彙/クイズ導線を残すため
/// `currentPodcast` を保持する既存方針に合わせる）。
enum PlayerPresentation: Equatable {
    /// プレイヤー UI を表示しない（未再生）。
    case hidden
    /// 全タブ共通の下部ミニプレイヤーのみ表示。
    case mini
    /// フルプレイヤーシートを表示。
    case expanded
}
