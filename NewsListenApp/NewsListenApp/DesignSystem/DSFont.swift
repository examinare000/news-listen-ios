//
//  DSFont.swift
//  NewsListenApp
//
//  Editorial デザインシステムのタイポグラフィトークン。
//  見出しは Apple 純正セリフ（New York, design: .serif）、メタ・本文は SF。
//  すべてテキストスタイル基準で定義し Dynamic Type のスケールを維持する（アクセシビリティ保持）。
//

import SwiftUI

/// Editorial テーマの書体トークン。
///
/// 見出し系は `design: .serif`（New York）で雑誌的な階層を作り、メタ・本文は SF。
/// いずれも `Font.system(_:design:)` のテキストスタイル基準なので、利用者の文字サイズ設定
/// （Dynamic Type）に追従する。固定 pt を避けることでアクセシビリティを損なわない。
enum DSFont {
    /// 画面タイトル（ナビゲーション見出し相当）。セリフ・太め。
    static let display = Font.system(.largeTitle, design: .serif).weight(.bold)
    /// セクション見出し。セリフ・semibold。
    static let title = Font.system(.title2, design: .serif).weight(.semibold)
    /// 記事タイトルなどリスト主要見出し。セリフ・semibold。
    static let headline = Font.system(.title3, design: .serif).weight(.semibold)
    /// 本文。SF。
    static let body = Font.system(.body)
    /// メタ情報（日時・長さ等）。SF。
    static let meta = Font.system(.subheadline)
    /// 補助キャプション。SF。
    static let caption = Font.system(.caption)
    /// エラー・フィードバック等のやや小さい補助テキスト（`.footnote` 相当・caption より僅かに大きい）。
    /// 安全に関わるエラー文言の可読性を落とさないため caption とは別に保持する。
    static let footnote = Font.system(.footnote)
    /// アイブロウ（ソース名など）。SF・semibold。呼び出し側で大文字＋トラッキングを与える。
    static let eyebrow = Font.system(.caption, design: .default).weight(.semibold)
}

extension View {
    /// アイブロウ表記（小さな大文字＋字間広め）を適用する。
    ///
    /// 雑誌の「REUTERS · 2時間前」のような上付きラベルに使う。`textCase(.uppercase)` と
    /// `tracking` でレターを開き、`inkSecondary` で控えめに置く。`Text` 単体にも
    /// 複数 `Text` を束ねた `HStack` 全体にも適用できるよう `View` 拡張で提供する。
    func dsEyebrow() -> some View {
        self
            .font(DSFont.eyebrow)
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(DSColor.inkSecondary)
    }
}
