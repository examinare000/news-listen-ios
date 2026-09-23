import XCTest
@testable import NewsListenApp

/// T-T12c-01（verifies: CI-T12c）。`FailureMessages.message(for:context:)` の文言写像（spec §2.5 D4）。
/// 全 case × 全 `FailureContext` を確かめ、`context` によって文言が変わらないことも確認する
/// （SG-S1-2 の割り当て表は case ごとに文言 1 つ。order.md:90）。
final class FailureMessagesTests: XCTestCase {

    private let allContexts: [FailureContext] = [.feed, .starred, .settings, .podcast]

    private func assertMessage(_ failure: ApiFailure, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        for context in allContexts {
            XCTAssertEqual(
                FailureMessages.message(for: failure, context: context),
                expected,
                "context=\(context) で文言が変わってはならない",
                file: file,
                line: line
            )
        }
    }

    func testNetworkReturnsURLErrorLocalizedDescription() {
        let error = URLError(.notConnectedToInternet)
        assertMessage(.network(error), equals: error.localizedDescription)
    }

    func testRateLimitedReturnsExistingJapaneseMessage() {
        assertMessage(.rateLimited(retryAfter: nil), equals: "リクエストが多すぎます。しばらくしてからお試しください。")
        assertMessage(.rateLimited(retryAfter: 60), equals: "リクエストが多すぎます。しばらくしてからお試しください。")
    }

    func testUnauthorizedReturnsHTTPError401() {
        assertMessage(.unauthorized, equals: "HTTP Error 401")
    }

    func testForbiddenReturnsHTTPError403() {
        assertMessage(.forbidden, equals: "HTTP Error 403")
    }

    func testNotFoundReturnsHTTPError404ForAllSubjects() {
        let subjects: [NotFoundSubject] = [.streak, .quota, .quiz, .credential, .session, .star]
        for subject in subjects {
            assertMessage(.notFound(subject: subject), equals: "HTTP Error 404")
        }
    }

    func testConflictReturnsHTTPError409() {
        assertMessage(.conflict, equals: "HTTP Error 409")
    }

    func testValidationReturnsHTTPError400() {
        assertMessage(.validation, equals: "HTTP Error 400")
    }

    func testServerReturnsHTTPErrorWithStatus() {
        assertMessage(.server(status: 500), equals: "HTTP Error 500")
    }

    func testUnknownReturnsHTTPErrorWithStatus() {
        assertMessage(.unknown(status: 404), equals: "HTTP Error 404")
        assertMessage(.unknown(status: 418), equals: "HTTP Error 418")
    }

    func testDecodingReturnsFixedMessage() {
        // .decoding は underlying を保持しないため詳細が落ちる（user 承認済みの文言差異。order.md:63）。
        assertMessage(.decoding, equals: "Decoding error")
    }
}
