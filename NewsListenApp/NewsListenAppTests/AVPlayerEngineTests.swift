import XCTest
import AVFoundation
@testable import NewsListenApp

// I-S3a: adapter 内部の stale ガード（旧 `PodcastViewModelTests` の issue #59 特性テスト 6 関数）。
// 関数名は移植の追跡のためそのまま残す（spec §7.2。T-M01〜T-M06。verifies: CI-A1）。
// AVFoundation 型を使い続けてよい（このファイルは `Podcast/Platform/` の adapter のテスト）。
@MainActor
final class AVPlayerEngineTests: XCTestCase {

    private func loadedEngine() -> AVPlayerEngine {
        let engine = AVPlayerEngine()
        _ = engine.load(url: URL(string: "https://storage.example.com/p1.mp3")!)
        return engine
    }

    // MARK: - issue #59: KVO コールバックの stale 実行対策

    func testShouldProcessPlayerItemCallbackTrueWhenMatchesCurrentItem() throws {
        let engine = loadedEngine()
        let currentItem = try XCTUnwrap(engine.player?.currentItem)

        XCTAssertTrue(engine.isCurrentItem(currentItem))
    }

    func testShouldProcessPlayerItemCallbackFalseForDifferentItem() {
        let engine = loadedEngine()
        let staleItem = AVPlayerItem(url: URL(string: "https://storage.example.com/stale.mp3")!)

        XCTAssertFalse(engine.isCurrentItem(staleItem))
    }

    func testShouldProcessPlayerItemCallbackFalseWhenPlayerNil() {
        let engine = AVPlayerEngine()
        let item = AVPlayerItem(url: URL(string: "https://storage.example.com/none.mp3")!)

        XCTAssertFalse(engine.isCurrentItem(item))
    }

    func testShouldProcessPlayerCallbackTrueWhenMatchesCurrentPlayer() throws {
        let engine = loadedEngine()
        let currentPlayer = try XCTUnwrap(engine.player)

        XCTAssertTrue(engine.isCurrentPlayer(currentPlayer))
    }

    func testShouldProcessPlayerCallbackFalseForDifferentPlayer() {
        let engine = loadedEngine()
        let stalePlayer = AVPlayer()

        XCTAssertFalse(engine.isCurrentPlayer(stalePlayer))
    }

    func testShouldProcessPlayerCallbackFalseWhenPlayerNil() {
        let engine = AVPlayerEngine()
        let player = AVPlayer()

        XCTAssertFalse(engine.isCurrentPlayer(player))
    }
}
