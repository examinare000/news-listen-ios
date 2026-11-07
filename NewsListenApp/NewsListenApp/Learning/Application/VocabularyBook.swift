//
//  VocabularyBook.swift
//  NewsListenApp
//
//  語の登録と重複の抑止、登録済みの語の保持。通信は port（`LearningGateway`）の向こうにある。
//

import Foundation
import Combine

/// 学習の取得・送信 port。実体は adapter が組む。
struct LearningGateway {
    let fetchVocabulary: () async throws -> (terms: [SavedTerm], count: Int)
    let saveVocabulary: (String, String) async throws -> Void
    let fetchTestSession: () async throws -> [VocabularyTestWord]
    let submitTestResult: (VocabularyTest) async throws -> Void
    let submitQuiz: (String, [Int]) async throws -> QuizGrade
}

struct SavedTerm: Equatable {
    let episodeId: String
    let term: String
}

struct VocabularyBookView: Equatable {
    let count: Int
    let firstTerms: [String]
}

struct RegisteredTerms: Equatable {
    let episodeId: String
    let terms: Set<String>
}

enum VocabularySaveReceipt: Equatable { case saved, alreadySaved, alreadySaving }

@MainActor
final class VocabularyBook: ObservableObject {
    @Published private(set) var savingTerms: Set<String> = []
    @Published private(set) var registered: RegisteredTerms?
    @Published private(set) var lastSaveFailed = false

    /// 古い応答の破棄に使う。公開しない。
    private var requestedEpisodeId: String?
    private let gateway: LearningGateway

    init(gateway: LearningGateway) {
        self.gateway = gateway
    }

    func book() async throws -> VocabularyBookView {
        let saved = try await gateway.fetchVocabulary()
        return VocabularyBookView(count: saved.count, firstTerms: saved.terms.prefix(5).map(\.term))
    }

    /// 呼ばれた時点で `registered` を空に置き換える。応答が古い（cancel 済み、または後から別のエピソードを求められた）ときは
    /// `CancellationError` を投げ、`registered` を変えない。
    func registeredTerms(episodeId: String) async throws -> RegisteredTerms {
        requestedEpisodeId = episodeId
        registered = RegisteredTerms(episodeId: episodeId, terms: [])
        let saved = try await gateway.fetchVocabulary()
        guard !Task.isCancelled, requestedEpisodeId == episodeId else { throw CancellationError() }
        let result = RegisteredTerms(
            episodeId: episodeId,
            terms: Set(saved.terms.filter { $0.episodeId == episodeId }.map { VocabularyTerm.normalize($0.term) })
        )
        registered = result
        return result
    }

    func save(episodeId: String, term: String) async throws -> VocabularySaveReceipt {
        let key = VocabularyTerm.normalize(term)
        if registered?.terms.contains(key) == true { return .alreadySaved }
        if savingTerms.contains(key) { return .alreadySaving }

        savingTerms.insert(key)
        defer { savingTerms.remove(key) }
        do {
            try await gateway.saveVocabulary(episodeId, term)
        } catch {
            lastSaveFailed = true
            throw error
        }
        // 別のエピソードに移っていたら足さない。
        if let current = registered, current.episodeId == episodeId {
            registered = RegisteredTerms(episodeId: episodeId, terms: current.terms.union([key]))
        }
        return .saved
    }

    func dismissSaveFailure() {
        lastSaveFailed = false
    }
}
