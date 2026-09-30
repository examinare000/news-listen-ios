import XCTest
import MediaPlayer
import os
@testable import NewsListenApp

// I-S3a: `NowPlayingCenter`（CP10）の本番 adapter と、解除 token の契約テスト（spec §7.6。T-P01〜T-P03）。
// このテストファイルは MediaPlayer のキー定数を使うため `import MediaPlayer` する（R-03 の対象外）。
final class MediaPlayerNowPlayingTests: XCTestCase {

    override func tearDown() {
        MediaPlayerNowPlaying().clear()
        super.tearDown()
    }

    // verifies: CI-N1, CI-N2
    func testP01_updateElapsedOverwritesElapsedAndDurationAndKeepsOtherKeys() {
        let nowPlaying = MediaPlayerNowPlaying()
        nowPlaying.update([
            MPMediaItemPropertyTitle: "title",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
        ])

        nowPlaying.updateElapsed(12, duration: 300)

        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(info?[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "title", "ほかのキーは残る")
    }

    // verifies: CI-N2, CI-N3
    func testP02_updateElapsedDoesNothingWhenTheInfoIsCleared() {
        let nowPlaying = MediaPlayerNowPlaying()
        nowPlaying.update([MPMediaItemPropertyTitle: "title"])
        nowPlaying.clear()

        nowPlaying.updateElapsed(12, duration: 300)

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo, "辞書が nil のときは何もしない")
    }

    // verifies: CI-N5（SG-8b）。token 単体の契約（MP を使わない）。
    func testP03_registrationCancelRunsTheRemovalOnlyOnceEvenWhenCalledConcurrently() {
        let removals = OSAllocatedUnfairLock(initialState: 0)
        let token = RemoteCommandRegistration(removal: { removals.withLock { $0 += 1 } })
        let other = RemoteCommandRegistration(removal: {})
        XCTAssertFalse(token.isCancelled)

        token.cancel()
        token.cancel()

        XCTAssertEqual(removals.withLock { $0 }, 1, "解除は 1 回だけ実行される")
        XCTAssertTrue(token.isCancelled)
        XCTAssertFalse(other.isCancelled, "別の token の登録は残る")

        let concurrentRemovals = OSAllocatedUnfairLock(initialState: 0)
        let concurrentToken = RemoteCommandRegistration(removal: { concurrentRemovals.withLock { $0 += 1 } })
        DispatchQueue.concurrentPerform(iterations: 100) { _ in concurrentToken.cancel() }

        XCTAssertEqual(concurrentRemovals.withLock { $0 }, 1, "100 並行に cancel しても解除は 1 回")
        XCTAssertTrue(concurrentToken.isCancelled)
    }
}
