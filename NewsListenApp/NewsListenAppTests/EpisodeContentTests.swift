import XCTest
@testable import NewsListenApp

/// Catalog の domain 型 `EpisodeContent` の表示の規則と、`PodcastSourceArticle.linkURL` を検証する。
///
/// domain の型だけを使い、通信のデータモデルとデコードには触れない。
/// 期待値は移動前の `ModelTests` の同名テスト（題のフォールバック・has*・ライセンス表示・リンク検証）の Then と同値。
final class EpisodeContentTests: XCTestCase {

    private func content(
        title: String = "題",
        intro: String = "イントロ",
        segments: [TranscriptSegment]? = nil,
        vocabulary: [VocabularyEntry]? = nil,
        quiz: [QuizQuestion]? = nil,
        sourceArticles: [PodcastSourceArticle]? = nil,
        sourceKind: String? = nil
    ) -> EpisodeContent {
        EpisodeContent(
            id: "e1", title: title, japaneseIntroText: intro, difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 120,
            segments: segments, vocabulary: vocabulary, quiz: quiz,
            sourceArticles: sourceArticles, sourceKind: sourceKind
        )
    }

    private let segment = TranscriptSegment(speaker: "A", text: "hello")
    private let vocabularyEntry = VocabularyEntry(term: "t", meaningJa: "m", example: "e")
    private let quizQuestion = QuizQuestion(question: "q", options: ["x", "y"])
    private let article = PodcastSourceArticle(articleId: "a1", title: "t", url: "https://example.com", source: "s")

    // MARK: - displayTitle

    // verifies: ios-rule-catalog-03
    func testDisplayTitleUsesTitleWhenPresent() {
        XCTAssertEqual(content(title: "速報タイトル", intro: "イントロテキスト").displayTitle, "速報タイトル")
    }

    // verifies: ios-rule-catalog-03
    func testDisplayTitleFallsBackToIntroWhenTitleEmpty() {
        XCTAssertEqual(content(title: "", intro: "イントロテキスト").displayTitle, "イントロテキスト")
    }

    // verifies: ios-rule-catalog-03
    func testDisplayTitleFallsBackToIntroWhenTitleIsWhitespaceOnly() {
        XCTAssertEqual(content(title: "   ", intro: "イントロテキスト").displayTitle, "イントロテキスト")
    }

    // verifies: ios-rule-catalog-03
    func testDisplayTitleFallsBackToDefaultWhenBothEmpty() {
        XCTAssertEqual(content(title: "", intro: "").displayTitle, "ニュースポッドキャスト")
    }

    // verifies: ios-rule-catalog-03
    func testDisplayTitleTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(content(title: " \n題 \n", intro: "i").displayTitle, "題")
        XCTAssertEqual(content(title: "", intro: "\n イントロ \n").displayTitle, "イントロ")
        XCTAssertEqual(content(title: " \n ", intro: " \n ").displayTitle, "ニュースポッドキャスト")
    }

    // MARK: - has*（nil・空・非空）

    // verifies: ios-rule-catalog-03
    func testHasTranscriptIsTrueOnlyForNonEmptySegments() {
        XCTAssertFalse(content(segments: nil).hasTranscript)
        XCTAssertFalse(content(segments: []).hasTranscript)
        XCTAssertTrue(content(segments: [segment]).hasTranscript)
    }

    // verifies: ios-rule-catalog-03
    func testHasVocabularyIsTrueOnlyForNonEmptyVocabulary() {
        XCTAssertFalse(content(vocabulary: nil).hasVocabulary)
        XCTAssertFalse(content(vocabulary: []).hasVocabulary)
        XCTAssertTrue(content(vocabulary: [vocabularyEntry]).hasVocabulary)
    }

    // verifies: ios-rule-catalog-03
    func testHasQuizIsTrueOnlyForNonEmptyQuiz() {
        XCTAssertFalse(content(quiz: nil).hasQuiz)
        XCTAssertFalse(content(quiz: []).hasQuiz)
        XCTAssertTrue(content(quiz: [quizQuestion]).hasQuiz)
    }

    // verifies: ios-rule-catalog-03
    func testHasSourceArticlesIsTrueOnlyForNonEmptySourceArticles() {
        XCTAssertFalse(content(sourceArticles: nil).hasSourceArticles)
        XCTAssertFalse(content(sourceArticles: []).hasSourceArticles)
        XCTAssertTrue(content(sourceArticles: [article]).hasSourceArticles)
    }

    // verifies: ios-rule-catalog-03
    func testHasFlagsAreIndependentOfEachOther() {
        let onlyQuiz = content(quiz: [quizQuestion])
        XCTAssertTrue(onlyQuiz.hasQuiz)
        XCTAssertFalse(onlyQuiz.hasTranscript)
        XCTAssertFalse(onlyQuiz.hasVocabulary)
        XCTAssertFalse(onlyQuiz.hasSourceArticles)
    }

    // MARK: - showsCcBySaLicense

    // verifies: ios-rule-catalog-03
    func testShowsCcBySaLicenseIsTrueOnlyForExactFeatured() {
        XCTAssertTrue(content(sourceKind: "featured").showsCcBySaLicense)
        for kind in [nil, "user", "unknown", "Featured", "FEATURED", "", " featured", "featured "] as [String?] {
            XCTAssertFalse(content(sourceKind: kind).showsCcBySaLicense, "sourceKind=\(String(describing: kind)) は false であるべき")
        }
    }

    // MARK: - PodcastSourceArticle.linkURL

    // verifies: ios-rule-catalog-05
    func testLinkURLAcceptsHttpAndHttpsRegardlessOfSchemeCase() {
        for url in ["http://example.com/b", "https://example.com/a", "HTTPS://example.com/c"] {
            let target = PodcastSourceArticle(articleId: "a", title: "t", url: url, source: "s")
            XCTAssertNotNil(target.linkURL, "url=\(url) は linkURL が非 nil であるべき")
        }
    }

    // verifies: ios-rule-catalog-05
    func testLinkURLRejectsNonWebSchemesAndInvalidStrings() {
        let cases = ["ftp://example.com/x", "javascript:alert(1)", "tel:000", "", "not a url", "/relative"]
        for url in cases {
            let target = PodcastSourceArticle(articleId: "a", title: "t", url: url, source: "s")
            XCTAssertNil(target.linkURL, "url=\(url) は linkURL が nil であるべき")
        }
    }

    // MARK: - 葉の値型の memberwise init と等値

    func testTranscriptSegmentKeepsMemberwiseInitWithoutRole() {
        let segment = TranscriptSegment(speaker: "A", text: "x")
        XCTAssertNil(segment.role)
        XCTAssertEqual(segment, TranscriptSegment(speaker: "A", text: "x", role: nil))
        XCTAssertNotEqual(segment, TranscriptSegment(speaker: "A", text: "x", role: "fact"))
    }
}
