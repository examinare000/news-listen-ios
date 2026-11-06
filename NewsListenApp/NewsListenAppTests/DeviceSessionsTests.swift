import XCTest
@testable import NewsListenApp

/// `DeviceSessions`（端末のセッションの一覧と失効）のテスト。404 の冪等と、返した配列が保持されないことを固定する。
@MainActor
final class DeviceSessionsTests: XCTestCase {

    private final class RevokeRecorder {
        var ids: [String] = []
    }

    private let rows = [
        DeviceSession(id: "s1", deviceLabel: "iPhone", createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, isCurrent: true),
        DeviceSession(id: "s2", deviceLabel: nil, createdAt: "2026-01-02T00:00:00Z", lastUsedAt: "2026-01-03T00:00:00Z", isCurrent: false),
    ]

    // verifies: ios-cmd-account-07, ios-test-004
    func testIosTest004_listReturnsGatewayRowsAndRethrowsFailure() async {
        let rows = self.rows
        let sut = DeviceSessions(gateway: .stub(listSessions: { rows }))
        let failing = DeviceSessions(gateway: .stub(listSessions: { throw ApiFailure.server(status: 500) }))

        let listed = try? await sut.list()

        XCTAssertEqual(listed, rows)
        do {
            _ = try await failing.list()
            XCTFail("失敗は投げられる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // verifies: ios-cmd-account-07, ios-rule-account-06
    func testIosRuleAccount06_revokeTreatsSessionNotFoundAsSuccess() async throws {
        let recorder = RevokeRecorder()
        let notFound = DeviceSessions(gateway: .stub(revokeSession: { id in
            recorder.ids.append(id)
            throw ApiFailure.notFound(subject: .session)
        }))
        let ok = DeviceSessions(gateway: .stub(revokeSession: { id in recorder.ids.append(id) }))

        try await notFound.revoke(id: "s1")
        try await ok.revoke(id: "s1")

        XCTAssertEqual(recorder.ids, ["s1", "s1"])
    }

    // verifies: ios-rule-account-06
    func testIosRuleAccount06_revokeRethrowsOtherFailuresUnchanged() async {
        let cases: [ApiFailure] = [.server(status: 500), .notFound(subject: .credential)]
        for failure in cases {
            let sut = DeviceSessions(gateway: .stub(revokeSession: { _ in throw failure }))

            do {
                try await sut.revoke(id: "s1")
                XCTFail("\(failure) は投げられる")
            } catch {
                XCTAssertEqual(error as? ApiFailure, failure)
            }
        }
    }

    // verifies: ios-cmd-account-07
    func testIosCmdAccount07_revokeOthersReturnsRevokedCount() async throws {
        let sut = DeviceSessions(gateway: .stub(revokeOtherSessions: { 3 }))

        let count = try await sut.revokeOthers()

        XCTAssertEqual(count, 3)
    }

    // verifies: ios-check-07, ios-test-108
    func testIosTest108_mutatingReturnedRowsDoesNotChangeNextList() async throws {
        let rows = self.rows
        let sut = DeviceSessions(gateway: .stub(listSessions: { rows }))

        var first = try await sut.list()
        first.removeAll()
        let second = try await sut.list()

        XCTAssertEqual(second, rows)
    }
}
