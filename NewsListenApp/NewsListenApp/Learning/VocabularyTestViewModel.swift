import Foundation
import Combine
import UIKit

/// 通信と 800ms フィードバック待機を純粋な状態機械へ接続する。
@MainActor
final class VocabularyTestViewModel: ObservableObject {
    @Published private(set) var machine = VocabularyTestStateMachine()

    let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func load() async {
        machine.restartLoading()
        do {
            let session = try await apiClient.fetchVocabularyTestSession()
            machine.start(items: session.items)
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
        let correct: Bool
        switch machine.feedback {
        case .correct:
            correct = true
            DSFeedback.shared.play(.correct)
        case .incorrect:
            correct = false
            DSFeedback.shared.play(.incorrect)
        case nil:
            return
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: correct ? "正解" : "不正解。正解は\(machine.revealedCorrectAnswer ?? "")"
        )

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
            _ = try await apiClient.submitVocabularyTestResult(machine.resultPayload)
            machine.markSubmitted()
        } catch {
            machine.markSubmissionFailed()
        }
    }
}
