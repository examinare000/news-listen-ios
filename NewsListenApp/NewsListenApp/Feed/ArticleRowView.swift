//
//  ArticleRowView.swift
//  NewsListenApp
//
//  Feed の記事1件の行表示。ソース・公開日・タイトルと関連スコアの横バーを示す（設計 §7）。
//

import SwiftUI

struct ArticleRowView: View {
    let article: Article

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.headline)
                .lineLimit(3)
            HStack {
                Text(article.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(article.publishedAt.prefix(10))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            scoreBar
        }
        .padding(.vertical, 4)
    }

    // スコア（0〜1）を横バーで可視化。
    private var scoreBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * clampedScore)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("関連スコア")
        .accessibilityValue(String(format: "%.0f%%", clampedScore * 100))
    }

    private var clampedScore: CGFloat {
        CGFloat(min(max(article.score, 0), 1))
    }
}
