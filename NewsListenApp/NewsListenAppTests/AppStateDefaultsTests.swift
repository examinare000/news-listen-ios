import XCTest
@testable import NewsListenApp

/// issue #163: iOS の既定難易度を toeic_600 に統一する（旧: toeic_900）。
@MainActor
final class AppStateDefaultsTests: XCTestCase {

    func testDefaultDifficultyIsToeic600WhenUnset() {
        // UserDefaults に保存済みの値が無い状態を保証してから初期化する。
        UserDefaults.standard.removeObject(forKey: "default_difficulty")

        let appState = AppState(sessionStore: InMemorySessionStore())

        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
    }
}
