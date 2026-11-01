import XCTest
@testable import NewsListenApp

/// AccountSettingsViewModel（表示名の保存・パスワード変更の状態と文言）のテスト。
@MainActor
final class AccountSettingsViewModelTests: XCTestCase {

    private struct OtherError: Error {}

    private let lengthMessage = "新しいパスワードは12〜20文字にしてください"

    private let alice = Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)
    private let alice2 = Subject(username: "alice", displayName: "Alice2", role: Role(rawValue: "user"), key: nil)
    private let bob = Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "user"), key: nil)

    private final class GatewayRecorder {
        var updatedNames: [String] = []
        var changes: [(current: String, new: String)] = []
    }

    /// 応答を保留し、テストが任意の時点で返せる gateway の相手役。
    @MainActor
    private final class PendingUpdate {
        private var continuation: CheckedContinuation<Subject, Error>?

        var isWaiting: Bool { continuation != nil }

        func park() async throws -> Subject {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func resume(with subject: Subject) {
            continuation?.resume(returning: subject)
            continuation = nil
        }
    }

    private func makeProfile(
        recorder: GatewayRecorder = GatewayRecorder(),
        updateError: Error? = nil,
        changeError: Error? = nil
    ) -> AccountProfile {
        let subject = alice2
        return AccountProfile(gateway: AccountGateway(
            updateProfile: { name in
                recorder.updatedNames.append(name)
                if let updateError { throw updateError }
                return subject
            },
            changePassword: { current, new in
                recorder.changes.append((current, new))
                if let changeError { throw changeError }
            }
        ))
    }

    private func makeLoggedInAppState(session: URLSessionProtocol? = nil) -> AppState {
        let appState = session.map { makeSubjectAwareAppState(session: $0) } ?? makeSubjectAwareAppState()
        appState.completeLogin(LoginReceipt(token: "tA", subject: alice))
        return appState
    }

    private func password(length: Int) -> String {
        String(repeating: "p", count: length)
    }

    // MARK: - 生成

    // verifies: ios-dec-81
    func testIosDec81_freshViewModelHasNoMessageAndIsNotSubmitting() {
        for profile in [makeProfile(), nil] {
            let vm = AccountSettingsViewModel(profile: profile)

            XCTAssertNil(vm.message)
            XCTAssertFalse(vm.isSubmitting)
        }
    }

    // MARK: - saveProfile

    // verifies: ios-dec-81
    func testIosDec81_saveProfileWritesConfirmedSubjectAndReportsSuccess() async {
        let recorder = GatewayRecorder()
        let vm = AccountSettingsViewModel(profile: makeProfile(recorder: recorder))
        let appState = makeLoggedInAppState()

        await vm.saveProfile(displayName: "Alice2", appState: appState)

        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2")
        XCTAssertEqual(vm.message, "表示名を更新しました")
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(recorder.updatedNames, ["Alice2"])
    }

    // verifies: ios-dec-81
    func testIosDec81_saveProfileDoesNotOverwriteSubjectWhoLoggedInDuringTheRequest() async throws {
        let pending = PendingUpdate()
        let profile = AccountProfile(gateway: AccountGateway(
            updateProfile: { _ in try await pending.park() },
            changePassword: { _, _ in }
        ))
        let vm = AccountSettingsViewModel(profile: profile)
        let appState = makeLoggedInAppState()

        let task = Task { await vm.saveProfile(displayName: "Alice2", appState: appState) }
        for _ in 0..<2000 where !pending.isWaiting { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(pending.isWaiting, "gateway が呼ばれるはず")
        XCTAssertTrue(vm.isSubmitting, "応答待ちの間は送信中")

        appState.completeLogin(LoginReceipt(token: "tB", subject: bob))
        pending.resume(with: alice2)
        await task.value

        XCTAssertEqual(appState.currentSubject?.displayName, "Bob", "前の主体の応答で次の主体を書き換えない")
        XCTAssertEqual(appState.currentSubject?.username, "bob")
        XCTAssertEqual(vm.message, "表示名を更新しました")
        XCTAssertFalse(vm.isSubmitting)
    }

    // verifies: ios-dec-81
    func testIosDec81_saveProfileFailureReportsMessageAndKeepsSubject() async {
        let errors: [Error] = [ApiFailure.server(status: 500), ApiFailure.validation, OtherError()]
        for error in errors {
            let vm = AccountSettingsViewModel(profile: makeProfile(updateError: error))
            let appState = makeLoggedInAppState()

            await vm.saveProfile(displayName: "Alice2", appState: appState)

            XCTAssertEqual(vm.message, "表示名の更新に失敗しました", "\(error)")
            XCTAssertEqual(appState.currentSubject, alice, "\(error)")
            XCTAssertFalse(vm.isSubmitting, "\(error)")
        }
    }

    // verifies: ios-dec-81
    func testIosDec81_saveProfileWithoutProfileDoesNothing() async {
        let vm = AccountSettingsViewModel(profile: nil)
        let appState = makeLoggedInAppState()

        await vm.saveProfile(displayName: "Alice2", appState: appState)

        XCTAssertNil(vm.message)
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(appState.currentSubject, alice)
    }

    // verifies: ios-dec-81
    func testIosDec81_saveProfileUsesTheProfileGivenAtInitNotTheAppStateClient() async {
        let json = #"{"username":"alice","role":"user","display_name":"Alice2"}"#
        let sessionOfProfile = MockURLSession(data: Data(json.utf8), statusCode: 200)
        let sessionOfAppState = MockURLSession(data: Data("{}".utf8), statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: sessionOfProfile)
        let vm = AccountSettingsViewModel(profile: AccountProfile(gateway: .live(apiClient: client)))
        let appState = makeLoggedInAppState(session: sessionOfAppState)

        await vm.saveProfile(displayName: "Alice2", appState: appState)

        XCTAssertEqual(sessionOfProfile.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(sessionOfProfile.lastRequest?.url?.path, "/auth/me")
        XCTAssertNil(sessionOfAppState.lastRequest, "呼出時点の appState の client は使わない")
        XCTAssertEqual(appState.currentSubject?.displayName, "Alice2")
    }

    // MARK: - changePassword

    // verifies: ios-contract-22
    func testIosContract22_changePasswordRejectsLengthViolationBeforeAnythingElse() async {
        for length in [11, 21] {
            for hasProfile in [true, false] {
                let recorder = GatewayRecorder()
                let vm = AccountSettingsViewModel(profile: hasProfile ? makeProfile(recorder: recorder) : nil)

                let succeeded = await vm.changePassword(current: "old", new: password(length: length), appState: makeLoggedInAppState())

                XCTAssertFalse(succeeded, "length \(length) profile \(hasProfile)")
                XCTAssertEqual(vm.message, lengthMessage, "length \(length) profile \(hasProfile)")
                XCTAssertTrue(recorder.changes.isEmpty, "length \(length) は gateway を呼ばない")
                XCTAssertFalse(vm.isSubmitting)
            }
        }
    }

    // verifies: ios-dec-81
    func testIosDec81_changePasswordWithoutProfileReturnsFalseAndKeepsMessage() async {
        let vm = AccountSettingsViewModel(profile: nil)

        let succeeded = await vm.changePassword(current: "old", new: password(length: 12), appState: makeLoggedInAppState())

        XCTAssertFalse(succeeded)
        XCTAssertNil(vm.message)
        XCTAssertFalse(vm.isSubmitting)
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_changePasswordSuccessReportsAndReturnsTrue() async {
        for length in [12, 20] {
            let recorder = GatewayRecorder()
            let vm = AccountSettingsViewModel(profile: makeProfile(recorder: recorder))
            let new = password(length: length)

            let succeeded = await vm.changePassword(current: "old", new: new, appState: makeLoggedInAppState())

            XCTAssertTrue(succeeded, "length \(length)")
            XCTAssertEqual(vm.message, "パスワードを変更しました", "length \(length)")
            XCTAssertEqual(recorder.changes.count, 1)
            XCTAssertEqual(recorder.changes.first?.current, "old")
            XCTAssertEqual(recorder.changes.first?.new, new)
            XCTAssertFalse(vm.isSubmitting)
        }
    }

    // verifies: ios-cmd-account-06
    func testIosCmdAccount06_changePasswordFailureMessagesDependOnCause() async {
        let cases: [(error: Error, message: String)] = [
            (ApiFailure.validation, "現在のパスワードが正しくありません"),
            (ApiFailure.server(status: 500), "パスワード変更に失敗しました"),
            (OtherError(), "パスワード変更に失敗しました"),
        ]
        for (error, message) in cases {
            let vm = AccountSettingsViewModel(profile: makeProfile(changeError: error))

            let succeeded = await vm.changePassword(current: "old", new: password(length: 12), appState: makeLoggedInAppState())

            XCTAssertFalse(succeeded, "\(error)")
            XCTAssertEqual(vm.message, message, "\(error)")
            XCTAssertFalse(vm.isSubmitting, "\(error)")
        }
    }
}
