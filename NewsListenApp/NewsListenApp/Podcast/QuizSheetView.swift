//
//  QuizSheetView.swift
//  NewsListenApp
//
//  エピソード理解度クイズの選択・送信・採点結果表示。
//

import SwiftUI

/// Podcast の公開設問を提示し、サーバー採点結果を表示するシート。
struct QuizSheetView: View {
    let podcast: Podcast
    let submit: @MainActor ([Int]) async throws -> QuizAnswerResponse

    @Environment(\.dismiss) private var dismiss
    @State private var selections: [Int?]
    @State private var grade: QuizAnswerResponse?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var isUnavailable = false

    init(
        podcast: Podcast,
        submit: @escaping @MainActor ([Int]) async throws -> QuizAnswerResponse
    ) {
        self.podcast = podcast
        self.submit = submit
        _selections = State(initialValue: Array(repeating: nil, count: podcast.quiz?.count ?? 0))
    }

    var body: some View {
        NavigationStack {
            Group {
                if isUnavailable || !podcast.hasQuiz {
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
                    let quizCount = podcast.quiz?.count ?? 0
                    Text("本編の内容を\(quizCount)問で振り返ります")
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                        .accessibilityLabel("本編の内容を\(quizCount)問で振り返ります")
                }

                ForEach(Array((podcast.quiz ?? []).enumerated()), id: \.offset) { questionIndex, question in
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

    private func scoreHeader(_ grade: QuizAnswerResponse) -> some View {
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
        let gradeItem = grade?.results.first { $0.questionIndex == questionIndex }
        let isSelected = selections[questionIndex] == optionIndex
        let isCorrect = gradeItem?.correctIndex == optionIndex
        let isSelectedIncorrect = gradeItem?.selectedIndex == optionIndex && gradeItem?.isCorrect == false
        let tint = isCorrect ? DSColor.success : (isSelectedIncorrect ? DSColor.danger : DSColor.ink)

        return Button {
            selections[questionIndex] = optionIndex
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
            Task { await submitAnswers() }
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
        .disabled(selections.contains(where: { $0 == nil }) || isSubmitting)
        .accessibilityHint("選択した回答を送信して採点します")
    }

    @MainActor
    private func submitAnswers() async {
        let answers = selections.compactMap { $0 }
        guard answers.count == selections.count else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let response = try await submit(answers)
            grade = response
            // 50% 以上の正解率なら positive 音を発火（即ち .correct）。
            // それ以下は negative 触覚（.incorrect の soft のみ、音なし）。
            let correctRate = Double(response.correctCount) / Double(response.total)
            DSFeedback.shared.play(correctRate >= 0.5 ? .correct : .incorrect)
            // VoiceOver ユーザーへ採点結果をアナウンス
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(response.correctCount)問中\(response.total)問正解"
            )
        } catch APIError.httpError(let statusCode) where statusCode == 404 {
            // 旧 backend・提供なしは警告にせず、クイズ自体を graceful-hide する。
            isUnavailable = true
        } catch {
            errorMessage = "採点結果を取得できませんでした。もう一度お試しください。"
        }
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
private let quizPreviewPodcast: Podcast = {
    let data = Data("""
    {
        "id":"preview-quiz",
        "type":"single",
        "article_ids":["a1"],
        "difficulty":"toeic_900",
        "audio_url":"https://example.com/audio.mp3",
        "japanese_intro_text":"コンテナ技術について振り返ります。",
        "duration_seconds":180,
        "created_at":"2026-07-29T00:00:00Z",
        "status":"completed",
        "quiz":[
            {"question":"What changed deployment?","options":["Containerization","Paper","Audio","Ink"]},
            {"question":"How many options are shown?","options":["One","Two","Three","Four"]},
            {"question":"Where is grading performed?","options":["Device","Server","Player","Cache"]}
        ]
    }
    """.utf8)
    return try! JSONDecoder().decode(Podcast.self, from: data)
}()

private func quizPreviewSubmit(_ answers: [Int]) async throws -> QuizAnswerResponse {
    let correctIndices = [0, 3, 1]
    return QuizAnswerResponse(
        correctCount: 2,
        total: 3,
        correctRate: 2.0 / 3.0,
        results: answers.enumerated().map { answer in
            let correctIndex = correctIndices[answer.offset]
            return QuizGradeResult(
                questionIndex: answer.offset,
                selectedIndex: answer.element,
                correctIndex: correctIndex,
                isCorrect: answer.element == correctIndex
            )
        }
    )
}

#Preview("Quiz / Light") {
    QuizSheetView(podcast: quizPreviewPodcast, submit: quizPreviewSubmit)
}

#Preview("Quiz / Dark") {
    QuizSheetView(podcast: quizPreviewPodcast, submit: quizPreviewSubmit)
        .preferredColorScheme(.dark)
}
#endif
