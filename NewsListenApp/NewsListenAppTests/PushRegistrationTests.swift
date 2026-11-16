import XCTest
@testable import NewsListenApp

/// `PushRegistration`（Push の application）の契約テスト。
///
/// 端末トークンの登録・保留・取消と、通知タップの保留 id を、`AppState` に触れずに確かめる。
/// 認証・主体の判定は closure で注入し、gateway は呼出を記録する double に置き換える。
@MainActor
final class PushRegistrationTests: XCTestCase {

    /// `register` の呼出を記録し、必要なら完了を保留する gateway の double。
    @MainActor
    private final class RecordingPushGateway {
        private(set) var registered: [String] = []
        var holds = false
        private var held: [CheckedContinuation<Void, Never>] = []

        var gateway: PushGateway {
            PushGateway(register: { @MainActor [self] token in
                if holds { await withCheckedContinuation { held.append($0) } }
                registered.append(token)
            })
        }

        func releaseAll() {
            let pending = held
            held = []
            pending.forEach { $0.resume() }
        }
    }

    /// 認証・主体・gateway の有無を後から切り替えられる、closure の箱。
    @MainActor
    private final class Flags {
        var isAuthenticated: Bool
        var isCurrentSubject = true
        var hasGateway = true
        init(isAuthenticated: Bool) { self.isAuthenticated = isAuthenticated }
    }

    @MainActor
    private final class Fixture {
        let recorder = RecordingPushGateway()
        let flags: Flags
        let push: PushRegistration

        init(isAuthenticated: Bool) {
            let recorder = recorder
            let flags = Flags(isAuthenticated: isAuthenticated)
            // `SubjectStamp` は `AppState.swift` の外から作れないので、本物の `AppState` から借りる。
            let stamp = makeSubjectAwareAppState().subjectStamp
            self.flags = flags
            push = PushRegistration(
                gateway: { flags.hasGateway ? recorder.gateway : nil },
                isAuthenticated: { flags.isAuthenticated },
                subjectStamp: { stamp },
                isCurrentSubject: { _ in flags.isCurrentSubject }
            )
        }
    }

    /// 投げっぱなしの task が走り切るまで MainActor を明け渡す。
    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    // MARK: - 登録

    func testRegisterIsNotSentWhenUnauthenticated() async {
        let fixture = Fixture(isAuthenticated: false)
        fixture.push.didReceiveDeviceToken("devicetokenhex")

        await fixture.push.registerIfPossible()
        await settle()

        XCTAssertEqual(fixture.recorder.registered, [], "未認証では登録を送らない")
    }

    func testSecondTokenCancelsPreviousRegistration() async {
        let fixture = Fixture(isAuthenticated: true)
        fixture.recorder.holds = true

        fixture.push.didReceiveDeviceToken("a")
        fixture.push.didReceiveDeviceToken("b")
        await settle()
        fixture.recorder.holds = false
        fixture.recorder.releaseAll()
        await settle()

        XCTAssertEqual(fixture.recorder.registered, ["b"], "前の予約は cancel され、後の token だけが 1 回送られる")
    }

    func testCancelPendingRegistrationPreventsSend() async {
        let fixture = Fixture(isAuthenticated: true)

        fixture.push.didReceiveDeviceToken("devicetokenhex")
        fixture.push.cancelPendingRegistration()
        await settle()

        XCTAssertEqual(fixture.recorder.registered, [], "cancel した予約は送らない")
    }

    func testRegistrationIsNotSentAfterSubjectChanged() async {
        let fixture = Fixture(isAuthenticated: true)

        fixture.push.didReceiveDeviceToken("devicetokenhex")
        fixture.flags.isCurrentSubject = false
        await settle()

        XCTAssertEqual(fixture.recorder.registered, [], "予約の後に主体が交代したら送らない（認証済みのままでも）")
    }

    func testRegisterIfPossibleSendsOnceWhenAuthenticated() async {
        let fixture = Fixture(isAuthenticated: true)
        fixture.push.didReceiveDeviceToken("devicetokenhex")

        await fixture.push.registerIfPossible()
        await settle()

        XCTAssertEqual(fixture.recorder.registered, ["devicetokenhex"])
    }

    func testTokenSurvivesCancelAndIsRegisteredForNextSubject() async {
        let fixture = Fixture(isAuthenticated: false)
        fixture.push.didReceiveDeviceToken("devicetokenhex")
        fixture.push.cancelPendingRegistration()
        await settle()
        XCTAssertEqual(fixture.recorder.registered, [], "前提: 離脱側では送っていない")

        fixture.flags.isAuthenticated = true
        await fixture.push.registerIfPossible()

        XCTAssertEqual(fixture.recorder.registered, ["devicetokenhex"], "cancel しても token は消えず、次の主体で同じ token を送る")
    }

    // MARK: - 通知タップの保留 id

    func testOpenEpisodeSetsPendingEpisodeId() {
        let fixture = Fixture(isAuthenticated: false)

        fixture.push.openEpisode(id: "pod123")

        XCTAssertEqual(fixture.push.pendingEpisodeId, "pod123", "未認証でも保留する")
    }

    func testConsumePendingEpisodeClearsOnlyMatchingId() {
        let fixture = Fixture(isAuthenticated: true)
        fixture.push.openEpisode(id: "a")
        fixture.push.openEpisode(id: "b")

        fixture.push.consumePendingEpisode(id: "a")
        XCTAssertEqual(fixture.push.pendingEpisodeId, "b", "古い id の消費で、後から来た id を消さない")

        fixture.push.consumePendingEpisode(id: "b")
        XCTAssertNil(fixture.push.pendingEpisodeId)
    }
}
