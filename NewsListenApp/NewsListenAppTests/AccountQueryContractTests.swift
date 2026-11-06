// verifies: ios-query-account-02
import XCTest
@testable import NewsListenApp

/// `DeviceSessions.list()`・`PasskeyEnrollment.credentials()`・`UserAdministration.users()` を読んでも、
/// 書込み（POST・PUT・PATCH・DELETE）が 0 件であることの契約テスト。
/// `RecordingURLSession` を `APIClient` に被せ、`AccountGateway.live(client:)` を通して数える。
@MainActor
final class AccountQueryContractTests: XCTestCase {

    private func makeRecording() -> (APIClient, RecordingURLSession, ScriptedURLSession) {
        let scripted = ScriptedURLSession()
        let recording = RecordingURLSession(delegate: scripted)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: "tok", session: recording)
        return (client, recording, scripted)
    }

    // verifies: ios-query-account-02, ios-check-09, ios-test-025
    func testIosTest025_listingSessionsDoesNotWrite() async throws {
        let (client, recording, scripted) = makeRecording()
        scripted.configure(
            method: "GET", path: "/auth/sessions", status: 200,
            body: Data(#"{"sessions":[{"id":"s1","device_label":"iPhone","created_at":"2026-01-01T00:00:00Z","last_used_at":null,"current":true}]}"#.utf8)
        )
        let sut = DeviceSessions(gateway: .live(client: { client }))

        let rows = try await sut.list()

        XCTAssertEqual(rows.map(\.id), ["s1"])
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-account-02, ios-check-09, ios-test-025
    func testIosTest025_listingCredentialsDoesNotWrite() async throws {
        let (client, recording, scripted) = makeRecording()
        scripted.configure(
            method: "GET", path: "/auth/passkey/credentials", status: 200,
            body: Data(#"{"credentials":[{"credential_id":"c1","username":"alice","name":"Key","transports":[],"sign_count":0,"created_at":"2026-01-01T00:00:00Z"}]}"#.utf8)
        )
        let sut = PasskeyEnrollment(gateway: .live(client: { client }), provider: MockPasskeyProvider())

        let rows = try await sut.credentials()

        XCTAssertEqual(rows.map(\.id), ["c1"])
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-account-02, ios-check-09, ios-test-025
    func testIosTest025_listingUsersDoesNotWrite() async throws {
        let (client, recording, scripted) = makeRecording()
        scripted.configure(
            method: "GET", path: "/admin/users", status: 200,
            body: Data(#"{"users":[{"username":"bob","role":"user","display_name":"Bob"}]}"#.utf8)
        )
        let sut = UserAdministration(gateway: .live(client: { client }), currentUsername: { nil })

        let rows = try await sut.users()

        XCTAssertEqual(rows.map(\.username), ["bob"])
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-check-09
    func testIosCheck09_revokingASessionCountsOneWrite() async throws {
        let (client, recording, _) = makeRecording()
        let sut = DeviceSessions(gateway: .live(client: { client }))

        try await sut.revoke(id: "s1")

        XCTAssertEqual(recording.writeCount, 1, "正の対照: DELETE は書込みとして数えられる")
    }
}
