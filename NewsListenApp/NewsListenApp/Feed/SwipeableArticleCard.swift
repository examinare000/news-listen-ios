//
//  SwipeableArticleCard.swift
//  NewsListenApp
//
//  Feed の記事カード（issue #111）。片手・直感的なジェスチャで操作する:
//  - 大きく右スワイプ → Star（Podcast 生成開始）
//  - 大きく左スワイプ → Dismiss（フィードから除外）
//  - タップ → タイトル全文 + Star/Dismiss ボタンを展開（トグル）
//  - ダブルタップ → 記事ソースをアプリ内ブラウザで表示
//  スワイプ中は方向・アクション（色・アイコン・指への追従）を可視化し、閾値到達で触覚フィードバック。
//

import SwiftUI

/// 記事 1 件のスワイプ操作対応カード。アクションは親（FeedView/FeedViewModel）へクロージャで委譲する。
struct SwipeableArticleCard: View {
    /// 表示する記事。
    let article: Article
    /// 全文展開中か。
    let isExpanded: Bool
    /// 単タップ（全文展開トグル）。
    let onTap: () -> Void
    /// ダブルタップ（ソースをブラウザ表示）。
    let onDoubleTap: () -> Void
    /// 右スワイプ確定（Star）。
    let onStar: () -> Void
    /// 左スワイプ確定（Dismiss）。
    let onDismiss: () -> Void

    /// アプリ全体で共有する設定状態（日付表記）。
    @EnvironmentObject private var appState: AppState
    /// 指への追従オフセット（横方向）。
    @State private var dragOffset: CGFloat = 0
    /// 閾値を越えているか（触覚フィードバックのトリガ）。
    @State private var crossedThreshold = false

    /// スワイプ確定とみなす移動量。
    private let threshold: CGFloat = 110

    var body: some View {
        ZStack {
            swipeAffordance
            cardContent
                .background(DSColor.paper)
                .offset(x: dragOffset)
                // simultaneousGesture: ScrollView の縦パンと共存させ、横優位のときだけ offset を反映する
                // （非 simultaneous だと縦スクロールを奪う既知の競合が起きるため）。
                .simultaneousGesture(dragGesture)
        }
        .clipped()
        // 閾値到達時に触覚フィードバック（越えた瞬間のみ）。
        .sensoryFeedback(trigger: crossedThreshold) { _, crossed in
            crossed ? .impact(weight: .medium) : nil
        }
    }

    /// スワイプ方向に応じた背景アフォーダンス（右=Star 金 / 左=Dismiss 赤）。
    private var swipeAffordance: some View {
        let swipingRight = dragOffset > 0
        return HStack {
            Label("スター", systemImage: "star.fill")
                .opacity(swipingRight ? 1 : 0)
            Spacer()
            Label("削除", systemImage: "xmark")
                .opacity(dragOffset < 0 ? 1 : 0)
        }
        .font(DSFont.body.weight(.semibold))
        .foregroundStyle(DSColor.onAccent)
        .padding(.horizontal, DSSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(swipingRight ? DSColor.star : (dragOffset < 0 ? DSColor.danger : Color.clear))
    }

    /// 記事の本体（アイブロウ・タイトル・関連スコア・展開時アクション）。
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s) {
            HStack(spacing: DSSpacing.s) {
                Text(article.source)
                Text("·")
                Text(formattedDate)
                Spacer(minLength: 0)
            }
            .dsEyebrow()

            Text(article.title)
                .font(DSFont.headline)
                .foregroundStyle(DSColor.ink)
                .lineLimit(isExpanded ? nil : 3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            RelevanceBar(score: article.score)
                .padding(.top, DSSpacing.xs)

            if isExpanded {
                HStack(spacing: DSSpacing.m) {
                    Button(action: onStar) {
                        Label("スター", systemImage: "star.fill")
                    }
                    .tint(DSColor.star)
                    Button(role: .destructive, action: onDismiss) {
                        Label("削除", systemImage: "xmark")
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
                .font(DSFont.caption)
                .padding(.top, DSSpacing.xs)
            }
        }
        .padding(.vertical, DSSpacing.m)
        .padding(.horizontal, DSSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // ダブルタップを先に登録し SwiftUI に count:2 を優先解決させる。
        // 単タップは二度押し判定待ちで僅かに遅延するが、競合はせず許容範囲。
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(count: 1, perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("記事: \(article.title)")
        .accessibilityHint("タップで全文展開、ダブルタップでソースを開きます")
        // VoiceOver からはスワイプできないため、Star/Dismiss をカスタムアクションとして公開する。
        .accessibilityAction(named: "スター", onStar)
        .accessibilityAction(named: "削除", onDismiss)
    }

    /// 横方向のスワイプジェスチャ。縦スクロールと競合しないよう横優位のときのみ追従する。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
                let crossed = abs(dragOffset) >= threshold
                if crossed != crossedThreshold {
                    crossedThreshold = crossed
                }
            }
            .onEnded { value in
                let width = value.translation.width
                let passed = abs(width) >= threshold
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffset = 0
                }
                crossedThreshold = false
                guard passed else { return }   // 閾値未満は元に戻す（操作しない）
                if width > 0 {
                    onStar()
                } else {
                    onDismiss()
                }
            }
    }

    /// timeFormat 設定に応じた日付表記。
    private var formattedDate: String {
        if appState.timeFormat == "relative" {
            return RelativeTimeFormatter.format(article.publishedAt)
        } else {
            return String(article.publishedAt.prefix(10))
        }
    }
}
