//
//  DSStreakToolbar.swift
//  NewsListenApp
//
//  主要画面で共有する聴取ストリークのコンパクト表示。
//

import SwiftUI

private struct DSStreakToolbarModifier: ViewModifier {
    @ObservedObject var engagement: EngagementStore
    /// アクセシビリティ：ユーザーが motion を削減する設定の場合、数字のカウントアップ遷移をスキップ。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.toolbar {
            if let streak = engagement.streak, streak.isShown {
                ToolbarItem(placement: .navigationBarLeading) {
                    DSBadge(
                        "\(streak.days)日連続",
                        tint: DSColor.accent
                    )
                    // 数字のカウントアップ遷移：Reduce Motion が enabled なら即時表示。
                    // このリポ初の Reduce Motion パターンを確立。
                    // iOS は accessibilityReduceMotion で transition/animation を条件分岐し、
                    // VoiceOver ユーザー等に配慮する（WCAG 2.1 Animation from Interactions）。
                    // ADR-086 決定 1：マスコット・炎アニメーション等は用いない。icon を削除し
                    // テキストのみのバッジで設計統一（Web と一致）。
                    .contentTransition(.numericText(value: Double(streak.days)))
                    .transaction { transaction in
                        if reduceMotion {
                            transaction.animation = nil
                        }
                    }
                    .accessibilityLabel("聴取ストリーク \(streak.days)日連続")
                }
            }
        }
    }
}

extension View {
    /// 聴取記録がある場合だけ navigation leading にストリークを表示する。
    func dsStreakToolbar(engagement: EngagementStore) -> some View {
        modifier(DSStreakToolbarModifier(engagement: engagement))
    }
}

#if DEBUG
#Preview("Streak Toolbar / Light") {
    NavigationStack {
        Text("フィード")
            .font(DSFont.body)
            .navigationTitle("フィード")
            .dsStreakToolbar(engagement: PreviewSamples.engagement(streakDays: 5))
    }
}

#Preview("Streak Toolbar / Dark") {
    NavigationStack {
        Text("フィード")
            .font(DSFont.body)
            .navigationTitle("フィード")
            .dsStreakToolbar(engagement: PreviewSamples.engagement(streakDays: 5))
    }
    .preferredColorScheme(.dark)
}
#endif
