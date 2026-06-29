//
//  RelevanceBar.swift
//  NewsListenApp
//
//  関連スコア（0〜1）を細い横バーで可視化する Editorial コンポーネント。
//  ArticleRowView から切り出し、トークン（accent / hairline）で再描画する。
//

import SwiftUI

/// 関連スコア（0〜1）を細い横バーで示すコンポーネント。
///
/// 雑誌的に主張しすぎない 3pt の極細バー。トラックは hairline、満たし部分は accent。
struct RelevanceBar: View {
    /// 0〜1 の範囲外も受け取り、描画時に丸める生スコア。
    let score: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DSColor.hairline)
                Capsule()
                    .fill(DSColor.accent)
                    .frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("関連スコア")
        .accessibilityValue(String(format: "%.0f%%", clamped * 100))
    }

    /// バー描画用に 0〜1 へ丸めた割合。
    private var clamped: CGFloat { CGFloat(min(max(score, 0), 1)) }
}
