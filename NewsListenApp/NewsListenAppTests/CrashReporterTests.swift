import XCTest
@testable import NewsListenApp

/// issue #83: クラッシュ整形（純粋関数）と /client-errors 送信のテスト。
/// MXCrashDiagnostic はテストで生成できないため、整形は原始値を受ける純粋関数に分離して検証する。
@MainActor
final class CrashReporterTests: XCTestCase {

    func testFormatterBuildsScrubbedPayload() {
        let p = CrashReportFormatter.payload(
            exceptionType: 1,
            exceptionCode: 0,
            signal: 11,
            terminationReason: "Namespace SIGNAL, Code 11",
            appVersion: "42"
        )

        XCTAssertEqual(p.source, "ios")
        XCTAssertEqual(p.kind, "crash")
        XCTAssertEqual(p.message, "Namespace SIGNAL, Code 11")
        XCTAssertEqual(p.context?["exception_type"], "1")
        XCTAssertEqual(p.context?["signal"], "11")
        XCTAssertEqual(p.context?["app_build"], "42")
    }

    func testFormatterTruncatesLongTerminationReason() {
        let long = String(repeating: "x", count: 1000)
        let p = CrashReportFormatter.payload(
            exceptionType: nil, exceptionCode: nil, signal: nil,
            terminationReason: long, appVersion: nil
        )
        XCTAssertEqual(p.message?.count, 500)
        // 全フィールド nil なら context は nil（空辞書を送らない）。
        XCTAssertNil(p.context)
    }

    func testFormatterNilMessageWhenNoReason() {
        let p = CrashReportFormatter.payload(
            exceptionType: 1, exceptionCode: nil, signal: nil,
            terminationReason: nil, appVersion: nil
        )
        XCTAssertNil(p.message)
        XCTAssertEqual(p.context?["exception_type"], "1")
    }

    func testReportClientErrorPostsToClientErrors() async throws {
        let session = MockURLSession(data: Data("{\"status\":\"ok\"}".utf8), statusCode: 202)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: nil,
            session: session
        )

        try await client.reportClientError(
            ClientErrorPayload(source: "ios", kind: "crash", message: "boom", context: ["signal": "11"])
        )

        XCTAssertEqual(session.lastRequest?.url?.path, "/client-errors")
        XCTAssertEqual(session.lastRequest?.httpMethod, "POST")
        // 認証セッション無し → Authorization ヘッダは付かない。
        XCTAssertNil(session.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(session.lastRequest?.value(forHTTPHeaderField: "X-API-Key"), "key")
    }
}
