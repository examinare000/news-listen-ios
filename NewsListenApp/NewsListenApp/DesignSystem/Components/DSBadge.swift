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

#if DEBUG
private struct DSTokenGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            Text("News Listen").font(DSFont.display).foregroundStyle(DSColor.ink)
            Text("Editorial Design Tokens").dsEyebrow()

            VStack(alignment: .leading, spacing: DSSpacing.s) {
                Text("見出し（serif）").font(DSFont.headline).foregroundStyle(DSColor.ink)
                Text("本文（SF）。読みやすさを優先する。").font(DSFont.body).foregroundStyle(DSColor.ink)
                Text("メタ情報").font(DSFont.caption).foregroundStyle(DSColor.inkSecondary)
            }

            HStack(spacing: DSSpacing.s) {
                DSBadge("TOEIC 900")
                DSBadge("生成中", systemImage: "hourglass", tint: DSColor.accent)
                DSBadge("失敗", systemImage: "exclamationmark.triangle.fill", tint: DSColor.danger)
            }

            RelevanceBar(score: 0.82).frame(width: 180)

            HStack(spacing: DSSpacing.s) {
                ForEach([DSColor.paper, DSColor.surface, DSColor.ink, DSColor.accent, DSColor.hairline], id: \.self) { c in
                    RoundedRectangle(cornerRadius: DSRadius.control)
                        .fill(c)
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.control).strokeBorder(DSColor.hairline))
                }
            }
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColor.paper)
    }
}

#Preview("Tokens / Light") { DSTokenGallery() }
#Preview("Tokens / Dark") { DSTokenGallery().preferredColorScheme(.dark) }
#endif
