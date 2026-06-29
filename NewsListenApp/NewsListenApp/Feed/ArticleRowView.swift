//
//  ArticleRowView.swift
//  NewsListenApp
//
//  Feed の記事1件の行表示。アイブロウ（ソース · 公開日）・セリフ見出し・関連スコアバーで
//  雑誌的な階層を作る（Editorial デザインシステム適用）。
//

import SwiftUI

/// Feed の記事1件の行表示。ソース・公開日・タイトルと関連スコアの横バーを示す（設計 §7）。
struct ArticleRowView: View {
    /// 表示する記事。
    let article: Article
    /// アプリ全体で共有する設定状態。
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s) {
            // アイブロウ: ソース · 公開日（小さな大文字＋字間広め）
            HStack(spacing: DSSpacing.s) {
                Text(article.source)
                Text("·")
                Text(formattedDate)
                Spacer(minLength: 0)
            }
            .dsEyebrow()

            // セリフ見出し（雑誌のリードタイトル）
            Text(article.title)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.ink)
                .lineLimit(3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            RelevanceBar(score: article.score)
                .padding(.top, DSSpacing.xs)
        }
        .padding(.vertical, DSSpacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("記事: \(article.title)")
        .accessibilityValue("ソース: \(article.source)、公開日: \(formattedDate)")
        .accessibilityHint("タップで記事を開きます。左スワイプでスター、右スワイプで削除できます")
    }

    /// timeFormat 設定に応じた日付表記を返す。
    private var formattedDate: String {
        if appState.timeFormat == "relative" {
            return RelativeTimeFormatter.format(article.publishedAt)
        } else {
            return String(article.publishedAt.prefix(10))
        }
    }
}
