import XCTest
@testable import NewsListenApp

// ロード失敗と「本当に空」を同一の空状態に畳んで表示してしまう不具合（issue #53）を防ぐため、
// 一覧画面の表示状態を決める純粋関数を独立してテストする。
final class ListDisplayStateTests: XCTestCase {

    func testResolveReturnsLoadingWhenLoadingAndEmpty() {
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: true, isEmpty: true, errorMessage: nil),
            .loading
        )
    }

    func testResolveReturnsErrorWhenErrorMessagePresentAndEmpty() {
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: false, isEmpty: true, errorMessage: "通信エラー"),
            .error(message: "通信エラー")
        )
    }

    // ロード中にエラーメッセージが残っていても、再ロード中はロード表示を優先する
    // （呼び出し元以外が両方 true の状態を作った場合の保護）。
    func testResolveReturnsLoadingWhenLoadingEvenIfErrorMessageRemains() {
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: true, isEmpty: true, errorMessage: "通信エラー"),
            .loading
        )
    }

    func testResolveReturnsEmptyWhenNoErrorAndEmpty() {
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: false, isEmpty: true, errorMessage: nil),
            .empty
        )
    }

    // 一覧に項目があれば、ロード中やエラーメッセージが残っていても一覧を優先して表示する
    // （エラーは別途アラートで表示済みのため、空状態表示には畳まない）。
    func testResolveReturnsContentWhenNotEmptyRegardlessOfLoadingOrError() {
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: true, isEmpty: false, errorMessage: "通信エラー"),
            .content
        )
        XCTAssertEqual(
            ListDisplayState.resolve(isLoading: false, isEmpty: false, errorMessage: nil),
            .content
        )
    }
}
