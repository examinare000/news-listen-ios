import Combine
import Foundation
import os
@testable import NewsListenApp

/// `PositionRecordStore` の in-memory 実装（port の double）。主体の `rawValue` を key に記録を持ち、
/// 書込・削除・回収の呼出を数える。失敗は `writeError`・`removeError`・`reclaimError` で注入する。
final class InMemoryPositionStore: @unchecked Sendable {
    struct Failure: Error, Equatable {}

    private struct State {
        var files: [String: [PositionRecord]] = [:]
        var writes = 0
        var removed: [String] = []
        var reclaimed: [String?] = []
        var writeError: Error?
        var removeError: Error?
        var reclaimError: Error?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var writeError: Error? {
        get { lock.withLock { $0.writeError } }
        set { lock.withLock { $0.writeError = newValue } }
    }

    var removeError: Error? {
        get { lock.withLock { $0.removeError } }
        set { lock.withLock { $0.removeError = newValue } }
    }

    var reclaimError: Error? {
        get { lock.withLock { $0.reclaimError } }
        set { lock.withLock { $0.reclaimError = newValue } }
    }

    /// `write` が呼ばれた回数（失敗した呼出も数える）。
    var writeCount: Int { lock.withLock { $0.writes } }
    var removeCount: Int { lock.withLock { $0.removed.count } }
    var reclaimCount: Int { lock.withLock { $0.reclaimed.count } }

    func resetCounts() {
        lock.withLock {
            $0.writes = 0
            $0.removed = []
            $0.reclaimed = []
        }
    }

    /// ファイルを持っている主体の `rawValue`。
    var subjectNames: Set<String> { lock.withLock { Set($0.files.keys) } }

    /// 主体の保存済みの記録。無ければ空。
    func stored(for subject: SubjectKey) -> [PositionRecord] {
        lock.withLock { $0.files[subject.rawValue] ?? [] }
    }

    /// 起動前から端末にあった記録を置く（`write` の回数には数えない）。
    func seed(_ records: [PositionRecord], for subject: SubjectKey) {
        lock.withLock { $0.files[subject.rawValue] = records }
    }

    var store: PositionRecordStore {
        PositionRecordStore(
            read: { [self] subject in lock.withLock { $0.files[subject.rawValue] ?? [] } },
            write: { [self] subject, records in
                try lock.withLock { state in
                    state.writes += 1
                    if let error = state.writeError { throw error }
                    state.files[subject.rawValue] = records
                }
            },
            removeSubject: { [self] subject in
                try lock.withLock { state in
                    state.removed.append(subject.rawValue)
                    if let error = state.removeError { throw error }
                    state.files[subject.rawValue] = nil
                }
            },
            reclaim: { [self] keeping in
                try lock.withLock { state in
                    state.reclaimed.append(keeping?.rawValue)
                    if let error = state.reclaimError { throw error }
                    state.files = state.files.filter { $0.key == keeping?.rawValue }
                }
            }
        )
    }
}

/// 既存の `PositionReporter` の組み立てに渡す、主体 A を束縛した `PositionRecords`。
@MainActor
func makeBoundPositionRecords(
    subject: SubjectKey = subjectA, store: InMemoryPositionStore = InMemoryPositionStore()
) -> PositionRecords {
    let records = PositionRecords(store: store.store)
    records.bind(subject: subject)
    return records
}

/// 何も流さない接続の購読（再送の契機を使わないテスト用）。
func makeSilentConnectivity() -> AnyPublisher<Bool, Never> {
    Empty<Bool, Never>().eraseToAnyPublisher()
}
