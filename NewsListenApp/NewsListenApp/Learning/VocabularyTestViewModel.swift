import Foundation
import Combine

/// 通信と 800ms フィードバック待機を純粋な状態機械へ接続する。
@MainActor
final class VocabularyTestViewModel: ObservableObject {
    @Published private(set) var machine = VocabularyTest()

    private let vocabularyTesting: VocabularyTesting

    init(vocabularyTesting: VocabularyTesting) {
        self.vocabularyTesting = vocabularyTesting
    }

    func load() async {
        machine.restartLoading()
        do {
            machine.start(items: try await vocabularyTesting.due().words)
        } catch {
            machine.markLoadingFailed()
        }
    }

    func assess(known: Bool) async {
        let transition = machine.recordSelfAssessment(known: known)
        if transition == .submit {
            await submit()
        }
    }

    func answerRetest(_ choice: String) async {
        guard machine.recordRetestChoice(choice) else { return }
        guard machine.feedback != nil else { return }

        try? await Task.sleep(for: .milliseconds(800))
        guard !Task.isCancelled else { return }
        if machine.finishRetestFeedback() == .submit {
            await submit()
        }
    }

    func retrySubmission() async {
        await submit()
    }

    func restart() async {
        await load()
    }

    private func submit() async {
        machine.markSubmitting()
        do {
            try await vocabularyTesting.submit(machine)
            machine.markSubmitted()
        } catch {
            machine.markSubmissionFailed()
        }
    }
}
