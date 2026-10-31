import XCTest
import os
@testable import NewsListenApp

/// `PositionReporter` が session の状態から現在位置を取り込むこと（ios-contract-13）の検証。
///
/// `positionChanged` を経ずに seek だけで動いた位置も、flush が送る値に反映されなければならない。
@MainActor
final class PositionReporterSeekPositionTests: XCTestCase {

    private final class Gateway: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [(id: String, seconds: Double)]())
        var updates: [(id: String, seconds: Double)] { lock.withLock { $0 } }

        func updatePosition(_ id: String, _ seconds: Double) -> Episode {
            lock.withLock { $0.append((id, seconds)) }
            let content = EpisodeContent(
                id: id, title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
                createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
                segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
            )
            return .playable(PlayableEpisode(content: content, audioUrl: "https://example.com/a.mp3", serverPosition: seconds)!)
        }
    }

    // verifies: ios-contract-13
    // kills: 状態の取込が timeUpdate 由来の位置だけで、seek の位置を flush に反映しない
    func testFlushSendsThePositionReachedBySeekWithoutAnyTimeUpdate() async throws {
        let engine = AudioEngineDouble()
        let session = PlaybackSession(engine: engine)
        let gateway = Gateway()
        let reporter = PositionReporter(
            updatePosition: { id, seconds in gateway.updatePosition(id, seconds) },
            markCompleted: { _ in },
            onPositionSaved: { _ in },
            onCompletionRecorded: {},
            beginBackgroundTask: { {} },
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        reporter.attach(session)
        let content = EpisodeContent(
            id: "a", title: "題 a", japaneseIntroText: "導入", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        let episode = try XCTUnwrap(PlayableEpisode(content: content, audioUrl: "https://storage.example.com/a.mp3", serverPosition: 0))

        session.start(episode: episode, url: URL(string: "https://storage.example.com/a.mp3")!, resumePosition: 0, speed: 1.0)
        await engine.send(.ready)
        XCTAssertEqual(session.state.episodeId, "a", "Given: 再生中（ready 済み）")
        XCTAssertTrue(gateway.updates.isEmpty, "Given: まだ何も送っていない")

        session.seek(to: 42)
        reporter.flush()

        let deadline = Date().addingTimeInterval(3)
        while gateway.updates.isEmpty, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(gateway.updates.map(\.id), ["a"])
        XCTAssertEqual(gateway.updates.map(\.seconds), [42])
    }
}
