import XCTest
import os
@testable import NewsListenApp

// ios-slice-playback-01: `AudioEngineDouble`（ハーネス）の契約テスト（spec §7.5。T-D01〜T-D05）。
// double が lost wakeup・ハング・偽 green を起こさないことを固定する
// （docs/trial-log/ios-scripted-session-lost-wakeup.md）。各テストは消費者 Task を最後に cancel してから await する。
@MainActor
final class AudioEngineDoubleTests: XCTestCase {

    private let url = URL(string: "https://storage.example.com/double.mp3")!

    // verifies: CI-D1（T-D01）
    func testD01_isLoadedFollowsLoadAndStopAndNextLoadWarningIsReturnedOnce() {
        let engine = AudioEngineDouble()
        XCTAssertFalse(engine.isLoaded)

        XCTAssertNil(engine.load(url: url))
        XCTAssertTrue(engine.isLoaded)

        engine.stop()
        XCTAssertFalse(engine.isLoaded)

        engine.nextLoadWarning = "session failed"
        XCTAssertEqual(engine.load(url: url), "session failed")
        XCTAssertTrue(engine.isLoaded, "再 load で読み込み済みに戻る")
        XCTAssertNil(engine.load(url: url), "nextLoadWarning は次の 1 回の load の戻り値になる")
    }

    // verifies: CI-D2（T-D02）
    func testD02_sendReturnsOnlyAfterConsumerProcessedTheEventAndNeverHangs() async {
        let engine = AudioEngineDouble()
        _ = engine.load(url: url)
        engine.play()
        let stream = engine.events
        let processed = OSAllocatedUnfairLock(initialState: 0)
        let consumer = Task {
            for await _ in stream {
                processed.withLock { $0 += 1 }
            }
        }

        for expected in 1...50 {
            await engine.send(.buffering)
            XCTAssertEqual(processed.withLock { $0 }, expected, "send が戻った時点で、その事象の処理が終わっている")
        }

        consumer.cancel()
        await consumer.value
    }

    // verifies: CI-D2（T-D03 ①〜④）
    func testD03_deliverYieldAndSendFollowTheFailureRulesOfTheChannel() async throws {
        // ① 消費者がいないとき deliver は timeout で false を返し、待受を外してから戻る。
        //    その後に消費者が来ても二重 resume しない（積まれた事象は 1 度だけ届く）。
        let engine = AudioEngineDouble()
        _ = engine.load(url: url)
        let channel = try XCTUnwrap(engine.currentChannel)
        let timedOut = await channel.deliver(.ready, timeout: 0.05)
        XCTAssertFalse(timedOut)
        XCTAssertFalse(channel.hasPendingDeliver, "timeout した待受は外れている")
        let received = OSAllocatedUnfairLock(initialState: [EngineEvent]())
        let stream = engine.events
        let consumer = Task {
            for await event in stream {
                received.withLock { $0.append(event) }
            }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(received.withLock { $0 }, [.ready], "timeout 後に来た消費者へ、積まれた事象が 1 度だけ届く")

        // ② 消費者が unfolding で待機中なら yield は .handedOff、いなければ .queued。
        XCTAssertEqual(channel.yield(.buffering), .handedOff)
        let idle = AudioEngineDouble()
        _ = idle.load(url: url)
        XCTAssertEqual(try XCTUnwrap(idle.currentChannel).yield(.buffering), .queued)

        consumer.cancel()
        await consumer.value

        // ③ stop の後、古い channel への deliver は待たずに false、yield は .dropped。
        let old = try XCTUnwrap(engine.currentChannel)
        engine.stop()
        let start = Date()
        let afterStop = await old.deliver(.ready, timeout: 5)
        XCTAssertFalse(afterStop)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "終了済みの channel では待たない")
        XCTAssertEqual(old.yield(.ready), .dropped)

        // ④ stop の後、古い channel への send は XCTFail を記録する（「黙って戻る」ミュータントを RED にする）。
        XCTExpectFailure("終了済みの channel への send は失敗として記録される（SR-11）")
        await old.send(.ready, timeout: 0.1)
    }

    // verifies: CI-D2（T-D04）
    func testD04_cancellingTheConsumerEndsTheStreamAndLaterDeliverReturnsFalseWithoutWaiting() async throws {
        let engine = AudioEngineDouble()
        _ = engine.load(url: url)
        engine.play()
        let channel = try XCTUnwrap(engine.currentChannel)
        let stream = engine.events
        let consumer = Task {
            for await _ in stream {}
        }
        await engine.send(.ready)

        consumer.cancel()
        await consumer.value  // onCancel で nil が返り、for await が終わる

        let start = Date()
        let result = await channel.deliver(.buffering, timeout: 5)
        XCTAssertFalse(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "cancel 済みの channel では待たない")
    }

    // verifies: CI-D2（T-D05。SR-13 / X1 / SR-14）
    func testD05_deliverDistinguishesProcessedThenClosedFromClosedBeforeTakenRegardlessOfSchedulingOrder() async throws {
        // (a) handler が起動した非構造化 Task が await を挟まずに stop する消費者への send（VM の ended → stop() と同じ形）。
        //     E が次の要求より先に走る順と後に走る順の両方を踏ませるため、load し直して 50 回繰り返す。
        let engine = AudioEngineDouble()
        for _ in 0..<50 {
            _ = engine.load(url: url)
            let channel = try XCTUnwrap(engine.currentChannel)
            let stream = engine.events
            let handled = OSAllocatedUnfairLock(initialState: false)
            let consumer = Task {
                for await _ in stream {
                    Task { engine.stop() }
                    handled.withLock { $0 = true }
                }
            }
            await channel.send(.ended)  // 処理済みの事象なので、後から channel が閉じても XCTFail しない
            XCTAssertTrue(handled.withLock { $0 })
            consumer.cancel()
            await consumer.value
        }

        // (b) 未取り出しの事象を待つ deliver が、stop で false・待たずに戻る（Given の成立を assert で確かめる）。
        _ = engine.load(url: url)
        let channel = try XCTUnwrap(engine.currentChannel)
        let waiting = Task { await channel.deliver(.ready, timeout: 5) }
        var spins = 0
        while !channel.hasPendingDeliver && spins < 100 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(channel.hasPendingDeliver, "Given: 別の Task の deliver が待受として登録済み")
        let start = Date()
        engine.stop()
        let result = await waiting.value
        XCTAssertFalse(result, "取り出される前に終了したので false")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "終了で待受を起こす（timeout まで待たない）")
    }

    // verifies: ios-contract-01（ios-test-077 の土台。ios-deriv-02）
    func testD06_perLoadEventsBeforePlayAreRejectedAndConnectionEventsAreNot() async throws {
        let engine = AudioEngineDouble()
        _ = engine.load(url: url)
        XCTAssertFalse(engine.hasStartedPlayback)

        // play() の前の読み込みごとの事象は届かず、失敗として記録される（実 adapter は play() で監視を登録する）。
        XCTExpectFailure("play() の前に読み込みごとの事象を送ると XCTFail する")
        await engine.send(.ready)

        // 割り込み系の事象は読み込み済みならいつでも送れる（XCTFail しない。消費者がいないので deliver は timeout で false）。
        let channel = try XCTUnwrap(engine.currentChannel)
        let delivered = await channel.deliver(.interrupted, timeout: 0.05)
        XCTAssertFalse(delivered, "消費者がいないので timeout で false（double の既存規則）")
    }

    // verifies: ios-contract-01（ios-test-077 の土台。ios-deriv-02）
    func testD07_loadedURLRateAndLastSeekFollowTheOperationsAndPlayResetsRateToOne() {
        let engine = AudioEngineDouble()
        XCTAssertNil(engine.loadedURL)
        XCTAssertFalse(engine.hasStartedPlayback)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertNil(engine.lastSeekSeconds)

        // 読み込み済みでないとき、操作は状態を変えない。
        engine.play()
        engine.setRate(2.0)
        engine.seek(to: 5)
        XCTAssertFalse(engine.hasStartedPlayback)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertNil(engine.lastSeekSeconds)

        _ = engine.load(url: url)
        XCTAssertEqual(engine.loadedURL, url)
        XCTAssertFalse(engine.hasStartedPlayback)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertNil(engine.lastSeekSeconds)

        engine.seek(to: 12.5)
        XCTAssertEqual(engine.lastSeekSeconds, 12.5)

        engine.setRate(1.5)
        engine.play()
        XCTAssertTrue(engine.hasStartedPlayback)
        XCTAssertEqual(engine.rate, 1.0, "play() は速度を 1.0 に戻す（実 adapter と同じ）")

        engine.setRate(1.5)
        XCTAssertEqual(engine.rate, 1.5)
        engine.pause()
        XCTAssertEqual(engine.rate, 0)

        let other = URL(string: "https://storage.example.com/other.mp3")!
        _ = engine.load(url: other)
        XCTAssertEqual(engine.loadedURL, other)
        XCTAssertFalse(engine.hasStartedPlayback, "load で未開始に戻る")
        XCTAssertNil(engine.lastSeekSeconds, "load で seek の記録が消える")

        engine.play()
        engine.stop()
        XCTAssertNil(engine.loadedURL)
        XCTAssertFalse(engine.hasStartedPlayback)
        XCTAssertEqual(engine.rate, 0)
        XCTAssertNil(engine.lastSeekSeconds)
    }
}
