import XCTest
@testable import NewsListenApp

/// `ScriptedURLSession` 自体の契約テスト。
///
/// 背景（2026-09-30）: ios PR #92 の CI（run 36511216822）で
/// `AppStateAuthTests.testTT14_18_outerCancellationDoesNotCancelPreferencesSync` が 6 時間ハングした。
/// 原因は `data(for:)` の `.pending` 経路で、到着通知（`waitUntilRequested` の待ち手を resume）と
/// `pendingContinuations` への登録が別のロック区間になっていたこと。テストが到着通知の直後に
/// `release` を呼ぶと、登録前なので「保留が無い」と判断されて捨てられ、その後に登録された
/// continuation は永遠に resume されない（lost wakeup）。
///
/// 本テストは「到着が観測できた時点で、release は必ず保留中のリクエストに届く」という契約を固定する。
/// 競合窓は外部から順序制御できないため反復で押さえ、ハングは expectation の timeout で失敗に変換する。
final class ScriptedURLSessionTests: XCTestCase {

    /// 到着通知の直後に release しても、保留中の data(for:) は必ず返る（lost wakeup を起こさない）。
    func testReleaseImmediatelyAfterArrivalAlwaysResumesPendingRequest() async {
        for iteration in 0..<50 {
            let scripted = ScriptedURLSession()
            scripted.configurePending(method: "GET", path: "/pending")

            let request = URLRequest(url: URL(string: "https://scripted.example.com/pending")!)
            let finished = expectation(description: "data(for:) returns (iteration \(iteration))")
            let task = Task<Int?, Never> {
                defer { finished.fulfill() }
                guard let (_, response) = try? await scripted.data(for: request) else { return nil }
                return (response as? HTTPURLResponse)?.statusCode
            }

            await scripted.waitUntilRequested(method: "GET", path: "/pending")
            scripted.release(method: "GET", path: "/pending", status: 204)

            let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            if result != .completed {
                // ハングを失敗に変換する。cancel すると onCancel が continuation を resume するので
                // `await task.value` が固まらない。
                task.cancel()
                XCTFail("iteration \(iteration): release が保留中のリクエストに届いていない（lost wakeup）")
                _ = await task.value
                return
            }
            let status = await task.value
            XCTAssertEqual(status, 204, "iteration \(iteration)")
        }
    }

    /// 到着前の release は「保留が無ければ何もしない」契約のまま（到着後の release で解放される）。
    func testReleaseBeforeArrivalIsIgnoredAndLaterReleaseResumes() async {
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/pending")
        scripted.release(method: "GET", path: "/pending", status: 500)

        let request = URLRequest(url: URL(string: "https://scripted.example.com/pending")!)
        let task = Task<Int?, Never> {
            guard let (_, response) = try? await scripted.data(for: request) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode
        }
        await scripted.waitUntilRequested(method: "GET", path: "/pending")
        scripted.release(method: "GET", path: "/pending", status: 200)

        let status = await task.value
        XCTAssertEqual(status, 200)
    }
}
