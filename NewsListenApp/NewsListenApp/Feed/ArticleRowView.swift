//
//  ArticleRowView.swift
//  NewsListenApp
//
//  Feed の記事1件の行表示。ソース・公開日・タイトルと関連スコアの横バーを示す（設計 §7）。
//

import SwiftUI

/// Feed の記事1件の行表示。ソース・公開日・タイトルと関連スコアの横バーを示す（設計 §7）。
struct ArticleRowView: View {
    /// 表示する記事。
    let article: Article
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

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
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            scoreBar
        }
        .padding(.vertical, 4)
    }

    /// timeFormat 設定に応じた日付表記を返す。
    private var formattedDate: String {
        if appState.timeFormat == "relative" {
            return RelativeTimeFormatter.format(article.publishedAt)
        } else {
            return String(article.publishedAt.prefix(10))
        }
    }

    /// スコア（0〜1）を横バーで可視化するサブビュー。
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

    /// バー描画用に 0〜1 の範囲へ丸めたスコア。
    private var clampedScore: CGFloat {
        CGFloat(min(max(article.score, 0), 1))
    }
}
