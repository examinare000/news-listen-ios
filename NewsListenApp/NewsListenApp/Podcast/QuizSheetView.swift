//
//  QuizSheetView.swift
//  NewsListenApp
//
//  エピソード理解度クイズの選択・送信・採点結果表示。
//

import SwiftUI

/// 再生中エピソードの公開設問を提示し、サーバー採点結果を表示するシート。
struct QuizSheetView: View {
    let nowPlaying: NowPlaying

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: QuizViewModel

    @MainActor
    init(nowPlaying: NowPlaying, grading: QuizGrading) {
        self.nowPlaying = nowPlaying
        _viewModel = StateObject(wrappedValue: QuizViewModel(
            grading: grading,
            episodeId: nowPlaying.episodeId,
            questionCount: nowPlaying.quiz?.count ?? 0
        ))
    }

    private var attempt: QuizAttempt { viewModel.attempt }
    private var grade: QuizGrade? { viewModel.grade }
    private var isSubmitting: Bool { viewModel.isSubmitting }
    private var errorMessage: String? { viewModel.errorMessage }
    private var isUnavailable: Bool { viewModel.isUnavailable }

    var body: some View {
        NavigationStack {
            Group {
                if isUnavailable || !nowPlaying.hasQuiz {
                    ContentUnavailableView(
                        "クイズを利用できません",
                        systemImage: "questionmark.circle",
                        description: Text("このエピソードにはクイズが用意されていません")
                    )
                } else {
                    quizContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsScreenBackground()
            .navigationTitle("理解度クイズ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var quizContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                if let grade {
                    scoreHeader(grade)
                } else {
                    let quizCount = nowPlaying.quiz?.count ?? 0
                    Text("本編の内容を\(quizCount)問で振り返ります")
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                        .accessibilityLabel("本編の内容を\(quizCount)問で振り返ります")
                }

                ForEach(Array((nowPlaying.quiz ?? []).enumerated()), id: \.offset) { questionIndex, question in
                    questionCard(question, index: questionIndex)
                }

                if grade == nil {
                    submitButton
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.danger)
                        .accessibilityLabel("エラー: \(errorMessage)")
                }
            }
            .padding(DSSpacing.l)
        }
    }

    private func scoreHeader(_ grade: QuizGrade) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("\(grade.correctCount) / \(grade.total) 正解")
                .font(DSFont.title)
                .foregroundStyle(DSColor.ink)
            Text("採点結果")
                .dsEyebrow()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(grade.total)問中\(grade.correctCount)問正解")
    }

    private func questionCard(_ question: QuizQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.m) {
            Text("Q\(index + 1). \(question.question)")
                .font(DSFont.headline)
                .foregroundStyle(DSColor.ink)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                optionButton(option, questionIndex: index, optionIndex: optionIndex)
            }
        }
        .dsCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("第\(index + 1)問: \(question.question)")
    }

    private func optionButton(_ option: String, questionIndex: Int, optionIndex: Int) -> some View {
        let gradeItem = grade?.perQuestion.first { $0.questionIndex == questionIndex }
        let isSelected = attempt.selection(for: questionIndex) == optionIndex
        let isCorrect = gradeItem?.correctIndex == optionIndex
        let isSelectedIncorrect = gradeItem?.selectedIndex == optionIndex && gradeItem?.isCorrect == false
        let tint = isCorrect ? DSColor.success : (isSelectedIncorrect ? DSColor.danger : DSColor.ink)

        return Button {
            viewModel.select(optionIndex, for: questionIndex)
        } label: {
            HStack(alignment: .top, spacing: DSSpacing.s) {
                Image(systemName: optionSymbol(
                    isSelected: isSelected,
                    isCorrect: isCorrect,
                    isSelectedIncorrect: isSelectedIncorrect
                ))
                Text(option)
                    .font(DSFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(DSSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isCorrect || isSelectedIncorrect || isSelected) ? tint.opacity(0.12) : DSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                    .strokeBorder(isSelected ? tint : DSColor.hairline)
            )
        }
        .buttonStyle(.plain)
        .disabled(grade != nil || isSubmitting)
        .accessibilityLabel(option)
        .accessibilityValue(optionAccessibilityValue(
            isSelected: isSelected,
            isCorrect: isCorrect,
            isSelectedIncorrect: isSelectedIncorrect
        ))
        .accessibilityHint(grade == nil ? "この回答を選択します" : "採点済みです")
    }

    private var submitButton: some View {
        Button {
            // 送信中にシートを閉じても採点の音と読み上げを届けるため、View に結びつかない Task で送る。
            Task { @MainActor in
                let vm = viewModel
                await vm.submit()
                guard let grade = vm.grade else { return }
                // 50% 以上の正解率なら positive 音を発火（即ち .correct）。
                // それ以下は negative 触覚（.incorrect の soft のみ、音なし）。
                DSFeedback.shared.play(grade.isPositive ? .correct : .incorrect)
                // VoiceOver ユーザーへ採点結果をアナウンス
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(grade.correctCount)問中\(grade.total)問正解"
                )
            }
        } label: {
            HStack(spacing: DSSpacing.s) {
                if isSubmitting {
                    ProgressView()
                        .tint(DSColor.onAccent)
                }
                Text(isSubmitting ? "採点中…" : "回答を送信")
                    .font(DSFont.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.m)
        }
        .buttonStyle(.borderedProminent)
        .tint(DSColor.accent)
        .disabled(!attempt.canSubmit || isSubmitting)
        .accessibilityHint("選択した回答を送信して採点します")
    }

    private func optionSymbol(
        isSelected: Bool,
        isCorrect: Bool,
        isSelectedIncorrect: Bool
    ) -> String {
        if isCorrect { return "checkmark.circle.fill" }
        if isSelectedIncorrect { return "xmark.circle.fill" }
        return isSelected ? "circle.inset.filled" : "circle"
    }

    private func optionAccessibilityValue(
        isSelected: Bool,
        isCorrect: Bool,
        isSelectedIncorrect: Bool
    ) -> String {
        if isCorrect { return "正解" }
        if isSelectedIncorrect { return "選択した不正解" }
        return isSelected ? "選択中" : "未選択"
    }
}

#if DEBUG
private let quizPreviewNowPlaying = NowPlaying(
    episodeId: "preview-quiz",
    displayTitle: "コンテナ技術について振り返ります。",
    japaneseIntroText: "コンテナ技術について振り返ります。",
    segments: nil,
    vocabulary: nil,
    quiz: [
        QuizQuestion(question: "What changed deployment?", options: ["Containerization", "Paper", "Audio", "Ink"]),
        QuizQuestion(question: "How many options are shown?", options: ["One", "Two", "Three", "Four"]),
        QuizQuestion(question: "Where is grading performed?", options: ["Device", "Server", "Player", "Cache"])
    ],
    difficulty: "toeic_900",
    sourceArticles: nil,
    sourceKind: nil,
    hasTranscript: false,
    hasVocabulary: false,
    hasQuiz: true,
    hasSourceArticles: false,
    showsCcBySaLicense: false,
    queueEntry: QueueEntry(
        episodeId: "preview-quiz",
        introText: "コンテナ技術について振り返ります。",
        difficulty: "toeic_900",
        durationSeconds: 180
    )
)

@MainActor
private func quizPreviewGrading() -> QuizGrading {
    let correctIndices = [0, 3, 1]
    return QuizGrading(gateway: LearningGateway(
        fetchVocabulary: { (terms: [], count: 0) },
        saveVocabulary: { _, _ in },
        fetchTestSession: { [] },
        submitTestResult: { _ in },
        submitQuiz: { _, answers in
            let items = answers.enumerated().map { answer in
                QuizGradeItem(
                    questionIndex: answer.offset,
                    selectedIndex: answer.element,
                    correctIndex: correctIndices[answer.offset],
                    isCorrect: answer.element == correctIndices[answer.offset]
                )
            }
            return QuizGrade(correctCount: 2, total: 3, perQuestion: items, isPositive: true)
        },
        fetchDashboard: { throw CancellationError() },
        fetchStreak: { throw CancellationError() }
    ))
}

#Preview("Quiz / Light") {
    QuizSheetView(nowPlaying: quizPreviewNowPlaying, grading: quizPreviewGrading())
}

#Preview("Quiz / Dark") {
    QuizSheetView(nowPlaying: quizPreviewNowPlaying, grading: quizPreviewGrading())
        .preferredColorScheme(.dark)
}
#endif
