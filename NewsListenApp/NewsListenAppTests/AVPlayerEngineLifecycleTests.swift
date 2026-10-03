import XCTest
import AVFoundation
import os
@testable import NewsListenApp

// I-S3a: `AVPlayerEngine` の寿命・配送規則のテスト（spec §7.4。T-A01〜T-A07）。
// 実 AVPlayer を使うが、ネットワークは要らない（ローカルに作った無音 WAV を読み込む）。
//
// 事象を数えるテストの注意: 実 AVPlayer を `play()` すると、ready / buffering / timeUpdate など
// 通知以外の事象も stream に流れうる。否定形の assert（「届かない」）は、検証対象の事象の種類だけを
// 数える（T-A04 は `ended`、T-A05〜T-A07 は割り込み・route 由来の事象）。
// `play()` を呼ばない load だけの adapter は load 固有の observer を持たないので、通知由来の事象しか流れない。
@MainActor
final class AVPlayerEngineLifecycleTests: XCTestCase {

    // MARK: - ヘルパー

    /// 無音の PCM WAV（8kHz / mono / 16bit）を一時ディレクトリへ書く。自然終端で `ended` が出ないよう十分長くする。
    private func makeSilentWAV(seconds: Int = 30) throws -> URL {
        let sampleRate = 8_000
        let dataSize = sampleRate * 2 * seconds
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append32(16)
        append16(1); append16(1); append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).wav")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// stream を購読して事象を記録する。最後に必ず cancel して await する。
    private final class Recorder {
        private let store = OSAllocatedUnfairLock(initialState: [EngineEvent]())
        private let finishedFlag = OSAllocatedUnfairLock(initialState: false)
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<EngineEvent>) {
            task = Task { [store, finishedFlag] in
                for await event in stream { store.withLock { $0.append(event) } }
                finishedFlag.withLock { $0 = true }
            }
        }

        var events: [EngineEvent] { store.withLock { $0 } }
        var isFinished: Bool { finishedFlag.withLock { $0 } }

        func wait(timeout: TimeInterval = 3, until predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return predicate()
        }

        func stop() async {
            task?.cancel()
            await task?.value
        }
    }

    private func postInterruption(began: Bool, shouldResume: Bool = false) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: (began ? AVAudioSession.InterruptionType.began : .ended).rawValue,
        ]
        if !began {
            userInfo[AVAudioSessionInterruptionOptionKey] =
                (shouldResume ? AVAudioSession.InterruptionOptions.shouldResume : []).rawValue
        }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
    }

    private func postRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        )
    }

    private func interruptionEvents(_ events: [EngineEvent]) -> [EngineEvent] {
        events.filter {
            switch $0 {
            case .interrupted, .interruptionEnded: return true
            default: return false
            }
        }
    }

    // MARK: - T-A01

    // verifies: CI-E1, CI-E6
    func testA01_loadCreatesPlayerStopRemovesItAndEngineIsReusable() throws {
        let engine = AVPlayerEngine()
        XCTAssertNil(engine.player)

        _ = engine.load(url: try makeSilentWAV())
        XCTAssertNotNil(engine.player)

        engine.stop()
        XCTAssertNil(engine.player)

        _ = engine.load(url: try makeSilentWAV())
        XCTAssertNotNil(engine.player, "stop の後も load で再利用できる")
    }

    // MARK: - T-A02

    // verifies: CI-E6, CI-A6
    func testA02_stopFinishesTheEventStreamWithinTimeout() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())
        let recorder = Recorder(engine.events)

        engine.stop()

        let finished = await recorder.wait { recorder.isFinished }
        XCTAssertTrue(finished, "stop で for await が timeout 内に終わる")
        await recorder.stop()
    }

    // MARK: - T-A03（positive control）

    // verifies: CI-A2（M8）。positive control: 否定形（T-A04）だけでは、observer が死んでいるミュータントを
    // 検出できない（docs/trial-log/ios-player-auto-converge.md:74-79）。
    func testA03_didPlayToEndOfTheCurrentItemPublishesEnded() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())
        let recorder = Recorder(engine.events)
        engine.play()
        let item = try XCTUnwrap(engine.player?.currentItem)

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)

        let received = await recorder.wait { recorder.events.contains(.ended) }
        XCTAssertTrue(received, "現在の item の終了通知は ended として stream に届く")
        engine.stop()
        await recorder.stop()
    }

    // MARK: - T-A04

    // verifies: CI-A2, CI-A6
    func testA04_didPlayToEndOfAnotherItemIsNotPublished() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())
        let recorder = Recorder(engine.events)
        engine.play()
        let otherItem = AVPlayerItem(url: try makeSilentWAV())

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: otherItem)
        try await Task.sleep(nanoseconds: 300_000_000)
        engine.stop()
        let finished = await recorder.wait { recorder.isFinished }

        XCTAssertTrue(finished)
        XCTAssertFalse(recorder.events.contains(.ended), "別の item の終了通知は publish されない")
        await recorder.stop()
    }

    // MARK: - T-A05（TV-3: 再 load 後の割り込み）

    // verifies: CI-A2（M9, M10。(ii)）, CI-A5
    func testA05_interruptionsAfterReloadReachTheNewStreamAndNotTheFinishedOne() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())   // 通知の登録は初回の load の時点
        let recorderA = Recorder(engine.events)
        engine.stop()
        let aFinished = await recorderA.wait { recorderA.isFinished }
        XCTAssertTrue(aFinished)
        let countAtStop = recorderA.events.count

        _ = engine.load(url: try makeSilentWAV())
        let recorderB = Recorder(engine.events)
        postInterruption(began: true)
        postInterruption(began: false, shouldResume: true)

        let received = await recorderB.wait { recorderB.events.count >= 2 }
        XCTAssertTrue(received, "load をやり直した後の割り込み通知が新しい stream に届く（登録時の continuation を閉じ込めない）")
        XCTAssertEqual(recorderB.events, [.interrupted, .interruptionEnded(shouldResume: true)])
        XCTAssertEqual(recorderA.events.count, countAtStop, "終了済みの stream には届かない")
        engine.stop()
        await recorderA.stop()
        await recorderB.stop()
    }

    // MARK: - T-A06（TV-3: 再 load 後の route change）

    // verifies: CI-A2（M11。(ii)。SG-4）
    func testA06_routeChangeAfterReloadPublishesOutputDeviceLostOnlyForOldDeviceUnavailable() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())
        let recorderA = Recorder(engine.events)
        engine.stop()
        let aFinished = await recorderA.wait { recorderA.isFinished }
        XCTAssertTrue(aFinished)
        let countAtStop = recorderA.events.count

        _ = engine.load(url: try makeSilentWAV())
        let recorderB = Recorder(engine.events)
        postRouteChange(.newDeviceAvailable)
        postRouteChange(.oldDeviceUnavailable)

        let received = await recorderB.wait { !recorderB.events.isEmpty }
        XCTAssertTrue(received)
        XCTAssertEqual(recorderB.events.first, .outputDeviceLost)
        engine.stop()
        _ = await recorderB.wait { recorderB.isFinished }
        XCTAssertEqual(recorderB.events, [.outputDeviceLost], "newDeviceAvailable では publish しない")
        XCTAssertEqual(recorderA.events.count, countAtStop)
        await recorderA.stop()
        await recorderB.stop()
    }

    // MARK: - T-A07（TV2-1: 再有効化フラグの規則）

    // verifies: CI-A5（SG-9）。`setActive(true)` の呼び出しそのものは観測しない（レビュー）。
    // 順序の意図: adapter が began と ended(shouldResume) を、VM の消費より先に両方受信した状況を作ってから
    // `pause()`（VM が遅れて `interrupted` を処理したときの呼び出し）を呼ぶ。
    func testA07_reactivationFlagIsSetByEndedResumeKeptByPauseAndConsumedBySetRate() async throws {
        let engine = AVPlayerEngine()
        _ = engine.load(url: try makeSilentWAV())
        let recorder = Recorder(engine.events)
        engine.play()

        postInterruption(began: true)
        postInterruption(began: false, shouldResume: true)
        let received = await recorder.wait { self.interruptionEvents(recorder.events).count >= 2 }

        XCTAssertTrue(received, "Given: 2 件とも受信済み（VM の消費より先に adapter が受信した状況）")
        XCTAssertEqual(interruptionEvents(recorder.events), [.interrupted, .interruptionEnded(shouldResume: true)])
        XCTAssertTrue(engine.needsSessionReactivation, "Given: ended(shouldResume) で立つ")

        engine.pause()
        XCTAssertTrue(engine.needsSessionReactivation, "pause ではフラグを倒さない（遅れて消費された interrupted が消してはならない）")

        engine.setRate(1)
        XCTAssertFalse(engine.needsSessionReactivation, "再開（setRate）で使って倒す")

        engine.stop()
        await recorder.stop()
    }
}
