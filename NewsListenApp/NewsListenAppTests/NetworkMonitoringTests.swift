import XCTest
@testable import NewsListenApp

@MainActor
final class NetworkMonitoringTests: XCTestCase {

    func testStubNetworkMonitorReturnsInitialValue() {
        let stub = StubNetworkMonitor(isOnline: true)
        XCTAssertTrue(stub.isOnline)
    }

    func testStubNetworkMonitorCanBeSetToOffline() {
        var stub = StubNetworkMonitor(isOnline: true)
        stub.isOnline = false
        XCTAssertFalse(stub.isOnline)
    }

    func testNetworkMonitorInitialIsOnline() {
        let monitor = NetworkMonitor()
        XCTAssertTrue(monitor.isOnline)
    }
}
