//
//  DSStreakToolbar.swift
//  NewsListenApp
//
//  主要画面で共有する聴取ストリークのコンパクト表示。
//

import SwiftUI

private struct DSStreakToolbarModifier: ViewModifier {
    @ObservedObject var appState: AppState
    /// アクセシビリティ：ユーザーが motion を削減する設定の場合、数字のカウントアップ遷移をスキップ。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.toolbar {
            if let streak = appState.listeningStreak,
               streak.lastListenedDay != nil,
               streak.currentStreakDays > 0 {
                ToolbarItem(placement: .navigationBarLeading) {
                    DSBadge(
                        "\(streak.currentStreakDays)日連続",
                        tint: DSColor.accent
                    )
                    // 数字のカウントアップ遷移：Reduce Motion が enabled なら即時表示。
                    // このリポ初の Reduce Motion パターンを確立。
                    // iOS は accessibilityReduceMotion で transition/animation を条件分岐し、
                    // VoiceOver ユーザー等に配慮する（WCAG 2.1 Animation from Interactions）。
                    // ADR-086 決定 1：マスコット・炎アニメーション等は用いない。icon を削除し
                    // テキストのみのバッジで設計統一（Web と一致）。
                    .contentTransition(.numericText(value: Double(streak.currentStreakDays)))
                    .transaction { transaction in
                        if reduceMotion {
                            transaction.animation = nil
                        }
                    }
                    .accessibilityLabel("聴取ストリーク \(streak.currentStreakDays)日連続")
                }
            }
        }
    }
}

extension View {
    /// 聴取記録がある場合だけ navigation leading にストリークを表示する。
    func dsStreakToolbar(appState: AppState) -> some View {
        modifier(DSStreakToolbarModifier(appState: appState))
    }
}

#if DEBUG
@MainActor
private func streakPreviewState() -> AppState {
    let state = AppState()
    state.listeningStreak = ListeningStreak(
        currentStreakDays: 5,
        todayListened: true,
        lastListenedDay: "2026-07-29"
    )
    return state
}

#Preview("Streak Toolbar / Light") {
    NavigationStack {
        Text("フィード")
            .font(DSFont.body)
            .navigationTitle("フィード")
            .dsStreakToolbar(appState: streakPreviewState())
    }
}

#Preview("Streak Toolbar / Dark") {
    NavigationStack {
        Text("フィード")
            .font(DSFont.body)
            .navigationTitle("フィード")
            .dsStreakToolbar(appState: streakPreviewState())
    }
    .preferredColorScheme(.dark)
}
#endif
