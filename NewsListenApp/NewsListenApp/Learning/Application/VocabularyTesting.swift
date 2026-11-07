//
//  VocabularyTesting.swift
//  NewsListenApp
//
//  単語テストの出題と送信。通信は port（`LearningGateway`）の向こうにある。
//

import Foundation

@MainActor
final class VocabularyTesting {
    private let gateway: LearningGateway

    init(gateway: LearningGateway) {
        self.gateway = gateway
    }

    /// 出題の上限（10 語）は domain の `VocabularyTest.start(items:)` が持つ。
    func due() async throws -> (words: [VocabularyTestWord], dueCount: Int) {
        var test = VocabularyTest()
        test.start(items: try await gateway.fetchTestSession())
        return (words: test.items, dueCount: test.items.count)
    }

    func submit(_ test: VocabularyTest) async throws {
        try await gateway.submitTestResult(test)
    }
}
