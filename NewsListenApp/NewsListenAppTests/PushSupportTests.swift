//
//  PushSupportTests.swift
//  NewsListenAppTests
//
//  APNs プッシュ通知（issue #80）の純粋ヘルパのテスト。
//

import XCTest
@testable import NewsListenApp

final class PushSupportTests: XCTestCase {

    // MARK: - DeviceTokenFormatter

    func testHexStringFromData() {
        let data = Data([0x00, 0x0f, 0xab, 0xff])
        XCTAssertEqual(DeviceTokenFormatter.hexString(from: data), "000fabff")
    }

    func testHexStringFromEmptyData() {
        XCTAssertEqual(DeviceTokenFormatter.hexString(from: Data()), "")
    }

    // MARK: - PushPayload

    func testPodcastIdPresent() {
        let userInfo: [AnyHashable: Any] = ["podcast_id": "pod123", "article_id": "art1"]
        XCTAssertEqual(PushPayload.podcastId(from: userInfo), "pod123")
    }

    func testPodcastIdAbsent() {
        let userInfo: [AnyHashable: Any] = ["article_id": "art1"]
        XCTAssertNil(PushPayload.podcastId(from: userInfo))
    }

    func testPodcastIdWrongType() {
        let userInfo: [AnyHashable: Any] = ["podcast_id": 123]
        XCTAssertNil(PushPayload.podcastId(from: userInfo))
    }
}
