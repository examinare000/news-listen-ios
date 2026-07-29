import SwiftUI

/// 2 択自己判定から「まだ」の語だけを意味選択へ進める最大 10 語のテスト。
struct VocabularyTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: VocabularyTestViewModel
    @GestureState private var dragOffset: CGSize = .zero
    @State private var exitOffset: CGFloat = 0
    @State private var isExiting = false

    @MainActor
    init(apiClient: APIClient) {
        _viewModel = StateObject(wrappedValue: VocabularyTestViewModel(apiClient: apiClient))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                switch viewModel.machine.phase {
                case .loading:
                    ProgressView("単語を準備しています")
                case .empty:
                    emptyState
                case .selfAssessment:
                    selfAssessment
                case .retest:
                    retest
                case .readyToSubmit, .submitting:
                    ProgressView("結果を記録しています")
                case .result:
                    result
                case .loadingError:
                    loadingError
                case .submissionError:
                    submissionError
                }
            }
            .frame(maxWidth: .infinity)
            .padding(DSSpacing.l)
        }
        .scrollContentBackground(.hidden)
        .dsScreenBackground()
        .navigationTitle("単語テスト")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private var selfAssessment: some View {
        VStack(spacing: DSSpacing.xl) {
            progress
            if let item = viewModel.machine.currentAssessment {
                VStack(spacing: DSSpacing.l) {
                    Text("この単語を知っていますか？")
                        .dsEyebrow()
                    Text(item.term)
                        .font(DSFont.display)
                        .foregroundStyle(DSColor.ink)
                    Text(item.example)
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.inkSecondary)
                        .multilineTextAlignment(.center)
                    Text("← まだ　／　知ってる →")
                        .font(DSFont.meta)
                        .foregroundStyle(DSColor.inkSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .dsCard()
                .offset(x: reduceMotion ? 0 : dragOffset.width * 0.4 + exitOffset)
                .rotationEffect(.degrees(reduceMotion ? 0 : dragOffset.width * 0.02))
                // 縦スクロール（ScrollView）と横スワイプを共存させるため simultaneousGesture で登録。
                // 横優位判定により横スワイプのみ応答（minimumDistance 20）。
                .simultaneousGesture(swipeDragGesture)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("この単語を知っていますか？ \(item.term)。例文: \(item.example)")

                HStack(spacing: DSSpacing.m) {
                    Button("まだ") { confirmAssessment(known: false) }
                        .buttonStyle(.bordered)
                        .tint(DSColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("この単語を意味選択で再確認します")
                    Button("知ってる") { confirmAssessment(known: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(DSColor.accent)
                        .frame(maxWidth: .infinity)
                        .accessibilityHint("次の単語へ進みます")
                }
                .disabled(isExiting)
            }
        }
    }

    private var retest: some View {
        VStack(spacing: DSSpacing.xl) {
            progress
            if let item = viewModel.machine.currentRetest {
                Text("意味を選んでください")
                    .dsEyebrow()
                Text(item.term)
                    .font(DSFont.display)
                    .foregroundStyle(DSColor.ink)
                VStack(spacing: DSSpacing.m) {
                    ForEach(Array((viewModel.machine.currentChoices ?? []).enumerated()), id: \.offset) {
                        _, choice in
                        Button {
                            Task { await viewModel.answerRetest(choice) }
                        } label: {
                            Text(choice)
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DSSpacing.l)
                                .background(DSColor.surface)
                                .overlay(alignment: .bottom) {
                                    if viewModel.machine.revealedCorrectAnswer == choice {
                                        Rectangle().fill(DSColor.accent).frame(height: 2)
                                    }
                                }
                                .clipShape(
                                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.machine.isAdvancing)
                    }
                }

                if case .correct = viewModel.machine.feedback {
                    Label("正解", systemImage: "checkmark.circle.fill")
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.accent)
                        .transition(
                            reduceMotion
                                ? AnyTransition.identity
                                : AnyTransition.scale.animation(.easeOut(duration: 0.3))
                        )
                        .accessibilityLabel("正解")
                } else if let correct = viewModel.machine.revealedCorrectAnswer {
                    Text("正解: \(correct)")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.ink)
                        .accessibilityLabel("正解は\(correct)")
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.3),
            value: viewModel.machine.feedback
        )
    }

    private var progress: some View {
        Text(viewModel.machine.progressText)
            .font(DSFont.meta.monospacedDigit())
            .foregroundStyle(DSColor.inkSecondary)
            .accessibilityLabel("進捗 \(viewModel.machine.progressText)")
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var result: some View {
        let summary = viewModel.machine.summary
        return VStack(spacing: DSSpacing.l) {
            Text("今回の記録").dsEyebrow()
            Text("知ってる \(summary.knownCount) 語")
                .font(DSFont.display)
                .foregroundStyle(DSColor.ink)
            if summary.retestCount == 0 {
                Text("すべて知っている単語でした")
                    .font(DSFont.body)
            } else {
                Text("再確認 \(summary.retestCount) 語中 \(summary.retestCorrectCount) 正解")
                    .font(DSFont.body)
            }
            Text("復習の間隔は自動で調整されます。")
                .font(DSFont.meta)
                .foregroundStyle(DSColor.inkSecondary)
            Button("もう一度テスト") {
                Task { await viewModel.restart() }
            }
            .buttonStyle(.borderedProminent)
            .tint(DSColor.accent)
            Button("エピソードを聴きに行く") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.accent)
            Button("ダッシュボードへ戻る") { dismiss() }
                .buttonStyle(.bordered)
                .tint(DSColor.ink)
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("いま復習する単語はありません", systemImage: "checkmark.circle")
        } description: {
            Text("次の学習タイミングで、またここに単語が届きます。")
        } actions: {
            Button("ダッシュボードへ戻る") { dismiss() }
        }
    }

    private var loadingError: some View {
        VStack(spacing: DSSpacing.l) {
            Text("読み込みに失敗しました").dsEyebrow()
            Text("もう一度試す").font(DSFont.title)
            Text("申し訳ありません。単語テストの読み込みに失敗しました。")
                .font(DSFont.body)
            Button("リロードする") { Task { await viewModel.restart() } }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.accent)
            Button("ダッシュボードへ戻る") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private var submissionError: some View {
        VStack(spacing: DSSpacing.l) {
            Text("送信に失敗しました").dsEyebrow()
            Text("もう一度送信する").font(DSFont.title)
            Text("ご回答は保存されていますので、以下のボタンから再度送信できます。")
                .font(DSFont.body)
            Button("送信を再試行する") {
                Task { await viewModel.retrySubmission() }
            }
            .buttonStyle(.borderedProminent)
            .tint(DSColor.accent)
            Button("キャンセルしてダッシュボードに戻る") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    private var swipeDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragOffset) { value, state, _ in
                guard !reduceMotion, !isExiting else { return }
                // 横優位判定: 縦移動より横移動が大きいときだけ state を更新。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation
            }
            .onEnded { value in
                guard !isExiting else { return }
                // 横優位判定を再度確認。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width >= 60 {
                    confirmAssessment(known: true)
                } else if value.translation.width <= -60 {
                    confirmAssessment(known: false)
                }
            }
    }

    private func confirmAssessment(known: Bool) {
        guard !isExiting else { return }
        if reduceMotion {
            Task { await viewModel.assess(known: known) }
            return
        }
        isExiting = true
        withAnimation(.easeOut(duration: 0.2)) {
            exitOffset = known ? 500 : -500
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await viewModel.assess(known: known)
            exitOffset = 0
            isExiting = false
        }
    }

    // ADR-088 の 5 語彙表: 自己判定確定時の触覚フィードバック（swipeConfirm）は発火させない。
    // web と統一し、クイズ段階での正誤判定フィードバックのみに限定する。
}

#if DEBUG
#Preview("Vocabulary Test / Light") {
    NavigationStack {
        VocabularyTestView(
            apiClient: APIClient(baseURL: URL(string: "https://example.com")!, apiKey: "preview")
        )
    }
}

#Preview("Vocabulary Test / Dark") {
    NavigationStack {
        VocabularyTestView(
            apiClient: APIClient(baseURL: URL(string: "https://example.com")!, apiKey: "preview")
        )
    }
    .preferredColorScheme(.dark)
}
#endif
