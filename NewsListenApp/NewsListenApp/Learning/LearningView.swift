import SwiftUI

/// 継続状況・実績・登録語彙・活動履歴を一つの紙面にまとめる第 5 タブ。
struct LearningView: View {
    @EnvironmentObject private var engagement: EngagementStore
    @StateObject private var viewModel: LearningViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let vocabularyTesting: VocabularyTesting

    @MainActor
    init(engagement: EngagementStore, vocabularyBook: VocabularyBook, vocabularyTesting: VocabularyTesting) {
        _viewModel = StateObject(wrappedValue: LearningViewModel(
            engagement: engagement, vocabularyBook: vocabularyBook, vocabularyTesting: vocabularyTesting))
        self.vocabularyTesting = vocabularyTesting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                    if !viewModel.newlyUnlocked.isEmpty {
                        achievementCelebration
                    }
                    if let dashboard = viewModel.dashboard {
                        progressSection(dashboard)
                        // 単語テスト導線は progressSection 直後に配置（期日 0 語なら非表示）。
                        if viewModel.dueVocabularyCount > 0 {
                            NavigationLink {
                                VocabularyTestView(vocabularyTesting: vocabularyTesting)
                            } label: {
                                Label("単語テスト", systemImage: "checkmark.rectangle.stack")
                                    .font(DSFont.body.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DSColor.accent)
                            .accessibilityHint("期日が来た単語を最大10語テストします")
                        }
                        achievementsSection(dashboard)
                        // 登録語彙の読み込み失敗時はセクション非表示（graceful）。
                        if viewModel.vocabulary != nil {
                            vocabularySection
                        }
                        historySection(dashboard)
                        accumulationSection(dashboard)
                        quizTrendSection(dashboard)
                    } else if viewModel.isLoading {
                        ProgressView("学習データを読み込んでいます")
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView(
                            "学習データを取得できませんでした",
                            systemImage: "book.closed",
                            description: Text("しばらくしてから再度お試しください")
                        )
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.25),
                    value: viewModel.newlyUnlocked
                )
                .padding(DSSpacing.l)
            }
            // 実績の解錠音は、新しい値が空でないときだけ鳴らす（閉じて `[]` になったときは鳴らさない）。
            .onChange(of: viewModel.newlyUnlocked) { _, newValue in
                if !newValue.isEmpty {
                    DSFeedback.shared.play(.achievement)
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .refreshable {
                await viewModel.load()
            }
            .navigationTitle("学習")
            .dsStreakToolbar(engagement: engagement)
            .toolbar {
                if viewModel.dashboard != nil || viewModel.loadFailed {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("再試行", systemImage: "arrow.clockwise") {
                            Task { await viewModel.load() }
                        }
                        .accessibilityLabel("学習データを再読み込み")
                    }
                }
            }
        }
        .task { await viewModel.load() }
    }

    private var achievementCelebration: some View {
        VStack(alignment: .leading, spacing: DSSpacing.s) {
            Text("実績を解錠しました")
                .font(DSFont.headline)
                .foregroundStyle(DSColor.accent)
            ForEach(viewModel.newlyUnlocked) { achievement in
                Text(achievementName(achievement.id))
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
            }
            Button("閉じる") { viewModel.dismissAchievementCelebration() }
                .font(DSFont.footnote)
        }
        .dsCard()
        .overlay(alignment: .leading) {
            Rectangle().fill(DSColor.accent).frame(width: 3)
        }
        .transition(reduceMotion ? .identity : .opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "実績を解錠しました。\(viewModel.newlyUnlocked.map { achievementName($0.id) }.joined(separator: "、"))"
        )
    }

    private func progressSection(_ dashboard: LearningDashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("今週の進捗")
                .font(DSFont.title)
                .foregroundStyle(DSColor.ink)
            let streak = engagement.streak ?? dashboard.streak
            if streak.isShown {
                Text("\(streak.days) 日連続")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.accent)
                    .contentTransition(.numericText(value: Double(streak.days)))
                    .transaction { if reduceMotion { $0.animation = nil } }
            }
            if let weekly = dashboard.weekly {
                Text("今週 \(weekly.completed)/目標 \(weekly.goal) 本")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                RelevanceBar(score: weekly.fraction)
                    .accessibilityLabel("今週の学習目標進捗")
                    .accessibilityValue("\(weekly.completed)本、目標\(weekly.goal)本")
            }
        }
        .dsCard()
    }

    private func achievementsSection(_ dashboard: LearningDashboardSummary) -> some View {
        let unlockedByID = Dictionary(
            uniqueKeysWithValues: dashboard.achievements.map { ($0.id, $0) }
        )
        return VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("実績")
                .font(DSFont.title)
                .foregroundStyle(DSColor.ink)
            ForEach(AchievementCatalog.all) { item in
                let unlocked = unlockedByID[item.id]
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(item.name)
                        .font(DSFont.headline)
                        .foregroundStyle(unlocked == nil ? DSColor.inkSecondary : DSColor.accent)
                    Text(item.description)
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                    if let unlocked {
                        Text("解錠: \(unlocked.unlockedAt)")
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Divider().overlay(DSColor.hairline)
            }
        }
        .dsCard()
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("登録語彙")
                .font(DSFont.title)
                .foregroundStyle(DSColor.ink)
            if let vocabulary = viewModel.vocabulary {
                Text("\(vocabulary.count) 語")
                    .font(DSFont.meta)
                    .foregroundStyle(DSColor.inkSecondary)
                ForEach(Array(vocabulary.firstEntries.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(item.term).font(DSFont.headline)
                        Text(item.meaning).font(DSFont.body)
                        Text(String(item.registeredAt.prefix(10)))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.inkSecondary)
                    }
                    .foregroundStyle(DSColor.ink)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .dsCard()
    }

    private func historySection(_ dashboard: LearningDashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            if !dashboard.weeklyHistory.isEmpty {
                VStack(alignment: .leading, spacing: DSSpacing.m) {
                    Text("週次履歴").font(DSFont.title)
                    ForEach(dashboard.weeklyHistory, id: \.week) { record in
                        activityRow(
                            title: record.week,
                            fact: "目標: \(record.progress.goal) → 実績: \(record.progress.completed)",
                            fraction: record.progress.fraction,
                            accessibilityValue: "目標\(record.progress.goal)本、実績\(record.progress.completed)本"
                        )
                    }
                }
            }
            if !dashboard.monthlyListeningDays.isEmpty {
                VStack(alignment: .leading, spacing: DSSpacing.m) {
                    Text("月別活動").font(DSFont.title)
                    ForEach(dashboard.monthlyListeningDays, id: \.month) { activity in
                        activityRow(
                            title: activity.month,
                            fact: "\(activity.days) 日",
                            fraction: Double(activity.days) / 31,
                            accessibilityValue: "\(activity.days)日"
                        )
                    }
                }
            }
        }
        .foregroundStyle(DSColor.ink)
        .dsCard()
    }

    private func accumulationSection(_ dashboard: LearningDashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("学習の蓄積").font(DSFont.title).foregroundStyle(DSColor.ink)
            VStack(alignment: .leading, spacing: DSSpacing.s) {
                Text("完聴エピソード数: \(dashboard.completedCount) 本")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                Text("習得語彙数: \(dashboard.masteredVocabularyCount) 語")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                Text("現在のレベル: \(dashboard.currentLevel)")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
            }
        }
        .dsCard()
    }

    private func quizTrendSection(_ dashboard: LearningDashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("クイズ成績の推移").font(DSFont.title).foregroundStyle(DSColor.ink)
            VStack(alignment: .leading, spacing: DSSpacing.s) {
                Text("出題エピソード数: \(dashboard.quizzedEpisodeCount) 本")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.ink)
                if let avgRate = dashboard.averageCorrectRate {
                    Text(String(format: "平均正答率: %.1f%%", avgRate * 100))
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.ink)
                } else {
                    Text("平均正答率: 未確定")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.inkSecondary)
                }
                if !dashboard.quizTrend.isEmpty {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("最新のトレンド").font(DSFont.meta).foregroundStyle(DSColor.inkSecondary)
                        ForEach(dashboard.quizTrend.suffix(3), id: \.date) { point in
                            HStack {
                                Text(String(point.date.prefix(10)))
                                    .font(DSFont.meta)
                                    .foregroundStyle(DSColor.inkSecondary)
                                Spacer()
                                Text(String(format: "%.0f%%", point.rate * 100))
                                    .font(DSFont.meta)
                                    .foregroundStyle(DSColor.accent)
                            }
                        }
                    }
                }
            }
        }
        .dsCard()
    }

    private func activityRow(
        title: String,
        fact: String,
        fraction: Double,
        accessibilityValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text(title).font(DSFont.meta)
                Spacer()
                Text(fact).font(DSFont.meta).foregroundStyle(DSColor.inkSecondary)
            }
            RelevanceBar(score: fraction)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
        }
    }

    private func achievementName(_ id: String) -> String {
        AchievementCatalog.all.first { $0.id == id }?.name ?? id
    }
}

#if DEBUG
@MainActor
private func learningPreview() -> some View {
    let engagement = PreviewSamples.engagement(streakDays: 5)
    return LearningView(
        engagement: engagement,
        vocabularyBook: PreviewSamples.vocabularyBook(),
        vocabularyTesting: PreviewSamples.vocabularyTesting()
    )
    .environmentObject(engagement)
}

#Preview("Learning / Light") {
    learningPreview()
}

#Preview("Learning / Dark") {
    learningPreview()
        .preferredColorScheme(.dark)
}
#endif
