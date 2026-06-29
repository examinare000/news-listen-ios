//
//  DSLayout.swift
//  NewsListenApp
//
//  Editorial デザインシステムの間隔・角丸トークンと共通レイアウト修飾子。
//  マジックナンバー（padding 12 等）を View に散らさず、ここに集約する。
//

import SwiftUI

/// 余白スケール（4 の倍数ベース）。`DSSpacing.l` のように参照する。
enum DSSpacing {
    /// 4pt。アイコンと文字の微調整など最小の隙間。
    static let xs: CGFloat = 4
    /// 8pt。要素内の小さな間隔。
    static let s: CGFloat = 8
    /// 12pt。行内の標準的な間隔。
    static let m: CGFloat = 12
    /// 16pt。カード内パディング・画面左右の標準余白。
    static let l: CGFloat = 16
    /// 24pt。ブロック間の余白。
    static let xl: CGFloat = 24
    /// 32pt。セクション間の大きな余白。
    static let xxl: CGFloat = 32
}

/// 角丸スケール。
enum DSRadius {
    /// 10pt。コントロール（ボタン等）。
    static let control: CGFloat = 10
    /// 14pt。カード。
    static let card: CGFloat = 14
}

extension View {
    /// 画面全体に紙（paper）の背景を敷く。`List` の場合は別途 `scrollContentBackground(.hidden)` と併用する。
    func dsScreenBackground() -> some View {
        background(DSColor.paper.ignoresSafeArea())
    }

    /// カード面（surface＋角丸＋繊細な影）を適用する。
    ///
    /// Editorial の落ち着いた奥行きのため、影は濃くせず淡く・近くに置く。
    func dsCard(padding: CGFloat = DSSpacing.l) -> some View {
        self
            .padding(padding)
            .background(DSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}
