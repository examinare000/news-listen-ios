//
//  NowPlayingInfoTests.swift
//  NewsListenAppTests
//
//  Now Playing 情報の組み立てと、割り込み/ルート変更ポリシーの純粋ロジックを検証する。
//  AVPlayer や MPNowPlayingInfoCenter の副作用を持たない純粋関数のみを対象にすることで、
//  バックグラウンド再生制御（issue #79）の中核ロジックを実機なしでテストする。
//

import XCTest
import AVFoundation
import MediaPlayer
@testable import NewsListenApp

@MainActor
final class NowPlayingInfoTests: XCTestCase {

    // MARK: - NowPlayingInfo.make

    func testMakeIncludesTitleDurationElapsedAndRate() {
        let info = NowPlayingInfo.make(snapshot: NowPlayingSnapshot(
            title: "t", subtitle: "s", elapsed: 42, duration: 300, rate: 1.5, isPlaying: true
        ))
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 42)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertNotNil(info[MPMediaItemPropertyTitle])
        // title と subtitle は加工せずに、それぞれ曲名とアーティスト名へ載せる。
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "t")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "s")
    }

    func testMakeRateIsZeroWhenPaused() {
        let info = NowPlayingInfo.make(snapshot: NowPlayingSnapshot(
            title: "t", subtitle: "s", elapsed: 10, duration: 300, rate: 1.0, isPlaying: false
        ))
        // 一時停止中はロック画面の進行を止めるため rate=0 を載せる。
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }

    func testMakeOmitsNonFiniteDuration() {
        let info = NowPlayingInfo.make(snapshot: NowPlayingSnapshot(
            title: "t", subtitle: "s", elapsed: 0, duration: Double.nan, rate: 1.0, isPlaying: true
        ))
        // duration 未確定（NaN）のときはキーを載せない（ロック画面の表示崩れ防止）。
        XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    }

    func testMakeClampsNegativeElapsedToZero() {
        let info = NowPlayingInfo.make(snapshot: NowPlayingSnapshot(
            title: "t", subtitle: "s", elapsed: -5, duration: 300, rate: 1.0, isPlaying: true
        ))
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
    }

    // MARK: - InterruptionPolicy

    func testShouldResumeTrueWhenOptionContainsShouldResume() {
        XCTAssertTrue(InterruptionPolicy.shouldResume(options: .shouldResume))
    }

    func testShouldResumeFalseWhenOptionEmpty() {
        XCTAssertFalse(InterruptionPolicy.shouldResume(options: []))
    }

    func testShouldPauseOnOldDeviceUnavailable() {
        // イヤホン抜去（旧デバイス喪失）では一時停止する。
        XCTAssertTrue(InterruptionPolicy.shouldPause(forRouteChangeReason: .oldDeviceUnavailable))
    }

    func testShouldNotPauseOnNewDeviceAvailable() {
        XCTAssertFalse(InterruptionPolicy.shouldPause(forRouteChangeReason: .newDeviceAvailable))
    }
}
