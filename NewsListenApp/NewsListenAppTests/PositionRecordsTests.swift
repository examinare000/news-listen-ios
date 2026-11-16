import XCTest
@testable import NewsListenApp

/// `PositionRecords`（端末の位置の記録の持ち主）。`InMemoryPositionStore` を port に使う。
@MainActor
final class PositionRecordsTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    /// 記録の時刻はミリ秒に切り捨てられるので、小数の誤差で t1 と同じ値にならないよう 1 秒離す。
    private var t2: Date { t1.addingTimeInterval(1) }

    private func makeRecords(
        _ store: InMemoryPositionStore, bound: SubjectKey? = subjectA
    ) -> PositionRecords {
        let records = PositionRecords(store: store.store)
        records.bind(subject: bound)
        return records
    }

    private func response(_ id: String, position: Double, at recordedAt: Date?) -> Episode {
        .playable(PlayableEpisode(
            content: EntryFixture.content(id), audioUrl: "https://cdn.example.com/\(id).mp3",
            serverPosition: position, serverRecordedAt: recordedAt)!)
    }

    private func record(_ subject: SubjectKey, _ id: String, _ seconds: Double, _ at: Date, sent: Bool = false) -> PositionRecord {
        PositionRecord(subject: subject, episodeId: id, seconds: seconds, recordedAt: at, isSent: sent)
    }

    // verifies: ios-cmd-playback-23
    // kills: 同じエピソードの記録が増える／時刻の大小で置換を拒む／保存せずメモリだけに持つ
    func testRecordKeepsOnlyTheLatestPerSubjectAndEpisodeAndPersistsEachWrite() {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)

        records.record(episodeId: "e", seconds: 10, at: t2)
        records.record(episodeId: "e", seconds: 5, at: t1)

        let unsent = records.unsent()
        XCTAssertEqual(unsent.count, 1)
        XCTAssertEqual(unsent.first?.seconds, 5, "書いた順が最新。時刻の大小で選ばない")
        XCTAssertEqual(unsent.first?.recordedAt, t1)
        XCTAssertEqual(unsent.first?.isSent, false)
        XCTAssertEqual(store.writeCount, 2)
        XCTAssertEqual(store.stored(for: subjectA).count, 1)
    }

    // verifies: ios-cmd-playback-23
    // kills: 主体を替えても前の主体の記録が見える／再束縛で記録を失う
    func testRecordsOfDifferentSubjectsAreIsolatedAfterRebind() {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        records.record(episodeId: "e", seconds: 10, at: t1)

        records.bind(subject: subjectB)
        XCTAssertTrue(records.unsent().isEmpty, "B からは A の記録が見えない")
        records.record(episodeId: "f", seconds: 20, at: t1)
        XCTAssertEqual(records.unsent().map(\.episodeId), ["f"])

        records.bind(subject: subjectA)
        XCTAssertEqual(records.unsent().map(\.episodeId), ["e"], "A に戻すと A の記録だけが見える")
    }

    // verifies: ios-cmd-playback-23
    // kills: 束縛なしで記録を作る・保存する
    func testRecordDoesNothingWithoutABoundSubject() {
        let store = InMemoryPositionStore()
        let records = makeRecords(store, bound: nil)

        XCTAssertNil(records.record(episodeId: "e", seconds: 10, at: t1))
        XCTAssertEqual(store.writeCount, 0)

        records.bind(subject: subjectA)
        XCTAssertNotNil(records.record(episodeId: "e", seconds: 10, at: t1), "対照: 束縛があれば記録する")
        XCTAssertEqual(store.writeCount, 1)
    }

    // verifies: ios-cmd-playback-23
    // kills: 保存の失敗で記録を捨てる・nil を返す・未送信から外す
    func testRecordKeepsTheRecordInMemoryWhenTheStoreWriteFails() throws {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        store.writeError = InMemoryPositionStore.Failure()

        let record = try XCTUnwrap(records.record(episodeId: "e", seconds: 10, at: t1), "保存に失敗しても記録を返す")

        XCTAssertEqual(records.unsent(), [record], "メモリ上の記録は送信の対象に残る")
        XCTAssertEqual(store.writeCount, 1, "保存は試みた")
        XCTAssertTrue(store.stored(for: subjectA).isEmpty, "対照: 保存先には書けていない")
    }

    // verifies: ios-query-playback-06
    // kills: 起動後に保存済みの未送信を読まない
    func testUnsentSurvivesRelaunchWithTheSameStore() {
        let store = InMemoryPositionStore()
        makeRecords(store).record(episodeId: "e", seconds: 10, at: t1)

        let relaunched = makeRecords(store)

        XCTAssertEqual(relaunched.unsent().map(\.episodeId), ["e"])
        XCTAssertEqual(relaunched.unsent().first?.seconds, 10)
    }

    // verifies: ios-cmd-playback-24
    // kills: 保存中の記録が引数と違うのに送信済みにする
    func testSettleMarksSentOnlyWhenTheStoredRecordIsTheSentOne() throws {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        let r1 = try XCTUnwrap(records.record(episodeId: "e", seconds: 10, at: t1))
        let r2 = try XCTUnwrap(records.record(episodeId: "e", seconds: 20, at: t2))

        _ = records.settle(r1, response: response("e", position: 10, at: nil))
        XCTAssertEqual(records.unsent().map(\.seconds), [20], "古い記録への応答で新しい記録は送信済みにならない")

        _ = records.settle(r2, response: response("e", position: 20, at: nil))
        XCTAssertTrue(records.unsent().isEmpty, "対照: 同じ記録への応答は送信済みにする")
    }

    // verifies: ios-cmd-playback-24
    // kills: 恒久の失敗で記録を消す／別の記録を送信済みにする
    func testSettleRejectedMarksSentAndKeepsTheRecord() throws {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        let r = try XCTUnwrap(records.record(episodeId: "e", seconds: 10, at: t1))

        records.settleRejected(r)
        XCTAssertTrue(records.unsent().isEmpty)
        XCTAssertEqual(store.stored(for: subjectA).map(\.seconds), [10], "記録は消さない")
        XCTAssertEqual(store.stored(for: subjectA).first?.isSent, true)

        let newer = try XCTUnwrap(records.record(episodeId: "e", seconds: 30, at: t2))
        records.settleRejected(r)
        XCTAssertEqual(records.unsent(), [newer], "古い記録への拒否で新しい記録は変わらない")
    }

    // verifies: ios-cmd-playback-24
    // kills: 同時刻・古い・時刻なしの応答で置き換える／記録の無いエピソードに記録を作る
    func testSettleAbsorbsOnlyAStrictlyNewerResponseAndDoesNotAbsorbEqualOrMissing() throws {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        let r = try XCTUnwrap(records.record(episodeId: "e", seconds: 10, at: t1))

        let newerTime = t1.addingTimeInterval(5)
        _ = records.settle(r, response: response("e", position: 99, at: newerTime))
        XCTAssertEqual(store.stored(for: subjectA).first,
                       PositionRecord(subject: subjectA, episodeId: "e", seconds: 99, recordedAt: newerTime, isSent: true))

        // 取り込み済みの記録（時刻 newerTime）に対し、同時刻・古い・時刻なしでは置き換えない。
        let absorbed = try XCTUnwrap(store.stored(for: subjectA).first)
        for time in [newerTime, newerTime.addingTimeInterval(-0.001), nil] as [Date?] {
            _ = records.settle(absorbed, response: response("e", position: 1, at: time))
            XCTAssertEqual(store.stored(for: subjectA).first?.seconds, 99, "時刻 \(String(describing: time)) の応答は取り込まない")
        }

        _ = records.settle(r, response: response("other", position: 7, at: newerTime.addingTimeInterval(9)))
        XCTAssertEqual(store.stored(for: subjectA).map(\.episodeId), ["e"], "記録の無いエピソードに記録を作らない")
    }

    // verifies: ios-cmd-playback-24
    // kills: 離脱・交代の後に届いた応答が次の主体の記録を書き換える
    func testSettleAfterRebindToAnotherSubjectChangesNothing() throws {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)
        let r = try XCTUnwrap(records.record(episodeId: "e", seconds: 10, at: t1))
        records.bind(subject: subjectB)
        let bRecord = try XCTUnwrap(records.record(episodeId: "e", seconds: 50, at: t2))
        store.resetCounts()

        let result = records.settle(r, response: response("e", position: 99, at: t2.addingTimeInterval(9)))

        XCTAssertNil(result)
        XCTAssertEqual(records.unsent(), [bRecord])
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(store.stored(for: subjectA).first?.isSent, false, "A のファイルも変えない")
    }

    // verifies: ios-cmd-playback-24
    // kills: reclaim が keeping の記録まで消す／束縛中の主体のキャッシュを失う
    func testReclaimKeepingAKeepsAAndRemovesOthers() throws {
        let store = InMemoryPositionStore()
        store.seed([record(subjectA, "e", 1, t1)], for: subjectA)
        store.seed([record(subjectB, "f", 2, t1)], for: subjectB)
        let records = makeRecords(store)

        try records.reclaim(keeping: subjectA)

        XCTAssertEqual(store.subjectNames, [subjectA.rawValue])
        XCTAssertEqual(records.unsent().map(\.episodeId), ["e"], "A の未送信は保たれる")
    }

    // verifies: ios-cmd-playback-24
    // kills: keeping が nil のとき消さない
    func testReclaimWithNilRemovesAll() throws {
        let store = InMemoryPositionStore()
        store.seed([record(subjectA, "e", 1, t1)], for: subjectA)
        store.seed([record(subjectB, "f", 2, t1)], for: subjectB)
        let records = makeRecords(store)

        try records.reclaim(keeping: nil)

        XCTAssertTrue(store.subjectNames.isEmpty)
        XCTAssertTrue(records.unsent().isEmpty)
    }

    // verifies: ios-query-playback-06
    // kills: 束縛なしで未送信を列挙する
    func testUnsentIsEmptyWhileUnbound() {
        let store = InMemoryPositionStore()
        store.seed([record(subjectA, "e", 1, t1)], for: subjectA)
        let records = makeRecords(store, bound: nil)

        XCTAssertTrue(records.unsent().isEmpty)

        records.bind(subject: subjectA)
        XCTAssertEqual(records.unsent().map(\.episodeId), ["e"], "対照: 束縛すると見える")
    }

    // verifies: ios-cmd-playback-23
    // kills: 位置の大小で巻き戻しを拒む
    func testRewoundPositionIsRecordedLikeAnyOther() {
        let store = InMemoryPositionStore()
        let records = makeRecords(store)

        records.record(episodeId: "e", seconds: 100, at: t1)
        records.record(episodeId: "e", seconds: 20, at: t2)

        XCTAssertEqual(records.unsent().map(\.seconds), [20])
        XCTAssertEqual(records.unsent().first?.recordedAt, t2)
    }
}
