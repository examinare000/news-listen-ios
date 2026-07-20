import XCTest
import Combine
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

    // MARK: - issue #54: View/ViewModel からの購読用パブリッシャ

    func testNetworkMonitorPublisherEmitsCurrentIsOnlineValue() {
        let monitor = NetworkMonitor()
        var received: Bool?
        let cancellable = monitor.isOnlinePublisher.sink { received = $0 }

        XCTAssertEqual(received, monitor.isOnline)
        cancellable.cancel()
    }

    func testStubNetworkMonitorPublisherEmitsIsOnlineValue() {
        let stub = StubNetworkMonitor(isOnline: false)
        var received: Bool?
        let cancellable = stub.isOnlinePublisher.sink { received = $0 }

        XCTAssertEqual(received, false)
        cancellable.cancel()
    }
}
