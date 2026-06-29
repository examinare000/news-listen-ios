//
//  DSBadge.swift
//  NewsListenApp
//
//  難易度・状態などを示す小さなピル型ラベル。Editorial トークンで統一する。
//

import SwiftUI

/// 小さなピル型ラベル（難易度・状態バッジ）。
///
/// 既定はアクセントの淡い面に accent 文字。`tint` を渡すと任意色の淡い面に切り替わる。
struct DSBadge: View {
    /// 表示文字列。
    let text: String
    /// 任意のシンボル名（先頭に表示）。
    var systemImage: String?
    /// 基調色（文字と淡い背景）。既定はアクセント。
    var tint: Color = DSColor.accent

    init(_ text: String, systemImage: String? = nil, tint: Color = DSColor.accent) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(DSFont.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, DSSpacing.s)
        .padding(.vertical, DSSpacing.xs)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
    }
}
