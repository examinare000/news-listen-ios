import XCTest
import os
@testable import NewsListenApp

// I-S3a: `AudioEngine` port の test double（spec §6.3 CI-D1〜D3）。production からは参照されない。
//
// 設計の要点（docs/trial-log/scripted-session-lost-wakeup.md の教訓）:
// - 到着の通知（消費者が次を要求した）と待受の登録を、必ず同じ `OSAllocatedUnfairLock` の区間で行う。
//   別々の区間に置くと、通知が待受の登録より先に走って取りこぼす（lost wakeup）。
// - continuation の resume はロックの外で行う（区間の中では resume する相手を取り出すだけ）。
// - 呼出回数は公開しない（SG-C26）。公開するのは状態（isLoaded / hasPendingDeliver / currentChannel）だけ。

/// `yield(_:)` の結果（stale 事象の注入専用。待たない）。
enum YieldResult: Equatable {
    /// 消費者が待機中で、その場で直接渡した。
    case handedOff
    /// 消費者がいないのでキューに積んだ。
    case queued
    /// channel が終了済みなので捨てた。
    case dropped
}

/// load ごとの channel の共有状態。unfolding と `onCancel` は MainActor の外から呼ばれうるので、
/// 状態はロックだけで守る（MainActor の隔離に頼らない）。
private final class ChannelCore: @unchecked Sendable {
    struct Entry {
        var event: EngineEvent
        var taken = false
        /// 取り出した unfolding の要求番号 + 1。要求回数がこれに達したら「処理し終えた」（CI-D2 ①）。
        var targetRequestCount = 0
    }

    struct DeliverWaiter {
        var entryId: Int
        var continuation: CheckedContinuation<Bool, Never>
    }

    struct State {
        var entries: [Int: Entry] = [:]
        var queue: [Int] = []
        var consumerWaiter: CheckedContinuation<EngineEvent?, Never>?
        var requestCount = 0
        var finished = false
        var nextEntryId = 0
        var nextWaiterId = 0
        var deliverWaiters: [Int: DeliverWaiter] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    // MARK: 消費者側（unfolding / onCancel）

    /// unfolding の 1 回の呼び出し。要求回数の加算と「キューが空なら待機者として登録」を同じ区間で行う。
    func next() async -> EngineEvent? {
        await withCheckedContinuation { (continuation: CheckedContinuation<EngineEvent?, Never>) in
            let effects: [() -> Void] = lock.withLockUnchecked { state in
                var effects: [() -> Void] = []
                state.requestCount += 1
                let request = state.requestCount
                // 目標の要求回数に達した「取り出し済み」事象の deliver は、ここで true になる（①）。
                effects += Self.resolveReachedDelivers(&state)
                if let id = state.queue.first {
                    state.queue.removeFirst()
                    state.entries[id]?.taken = true
                    state.entries[id]?.targetRequestCount = request + 1
                    let event = state.entries[id]!.event
                    effects.append { continuation.resume(returning: event) }
                } else if state.finished {
                    effects.append { continuation.resume(returning: nil) }
                } else {
                    state.consumerWaiter = continuation
                }
                return effects
            }
            effects.forEach { $0() }
        }
    }

    /// stop と、消費者 Task の cancel（`onCancel`）。待機者に nil を返し、deliver の待受を起こす。
    func finish() {
        let effects: [() -> Void] = lock.withLockUnchecked { state in
            guard !state.finished else { return [] }
            state.finished = true
            var effects: [() -> Void] = []
            if let waiter = state.consumerWaiter {
                state.consumerWaiter = nil
                effects.append { waiter.resume(returning: nil) }
            }
            // 取り出し済みなら true（②）、未取り出しなら false（③）。未取り出しの事象は捨てる。
            for (id, waiter) in state.deliverWaiters {
                let taken = state.entries[waiter.entryId]?.taken ?? false
                state.deliverWaiters.removeValue(forKey: id)
                effects.append { waiter.continuation.resume(returning: taken) }
            }
            state.queue.removeAll()
            return effects
        }
        effects.forEach { $0() }
    }

    // MARK: テスト側（send / deliver / yield）

    /// 積む（または待機者へ直接渡す）。判定は呼んだ時点で同期的に済む。
    func deliver(_ event: EngineEvent, timeout: TimeInterval) async -> Bool {
        var timer: Task<Void, Never>?
        let outcome: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let (waiterId, effects): (Int?, [() -> Void]) = lock.withLockUnchecked { state in
                if state.finished {
                    // ③ 呼んだ時点で終了済み（取り出される前に終了した扱い）。
                    return (nil, [{ continuation.resume(returning: false) }])
                }
                let entryId = state.nextEntryId
                state.nextEntryId += 1
                state.entries[entryId] = Entry(event: event)
                var effects: [() -> Void] = []
                if let consumer = state.consumerWaiter {
                    state.consumerWaiter = nil
                    state.entries[entryId]?.taken = true
                    state.entries[entryId]?.targetRequestCount = state.requestCount + 1
                    effects.append { consumer.resume(returning: event) }
                } else {
                    state.queue.append(entryId)
                }
                let waiterId = state.nextWaiterId
                state.nextWaiterId += 1
                state.deliverWaiters[waiterId] = DeliverWaiter(entryId: entryId, continuation: continuation)
                return (waiterId, effects)
            }
            effects.forEach { $0() }
            if let waiterId {
                // ④ timeout。待受を外してから false で戻る（ハングさせない）。
                timer = Task { [self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    expire(waiterId)
                }
            }
        }
        timer?.cancel()
        return outcome
    }

    func yield(_ event: EngineEvent) -> YieldResult {
        let (result, effects): (YieldResult, [() -> Void]) = lock.withLockUnchecked { state in
            if state.finished { return (.dropped, []) }
            let entryId = state.nextEntryId
            state.nextEntryId += 1
            state.entries[entryId] = Entry(event: event)
            if let consumer = state.consumerWaiter {
                state.consumerWaiter = nil
                state.entries[entryId]?.taken = true
                state.entries[entryId]?.targetRequestCount = state.requestCount + 1
                return (.handedOff, [{ consumer.resume(returning: event) }])
            }
            state.queue.append(entryId)
            return (.queued, [])
        }
        effects.forEach { $0() }
        return result
    }

    /// 未取り出しの事象を待っている deliver の待受が 1 つ以上登録されているか（CI-D2 の観測点）。
    var hasPendingDeliver: Bool {
        lock.withLockUnchecked { state in
            state.deliverWaiters.values.contains { !(state.entries[$0.entryId]?.taken ?? false) }
        }
    }

    // MARK: 内部

    private func expire(_ waiterId: Int) {
        let effect: (() -> Void)? = lock.withLockUnchecked { state in
            guard let waiter = state.deliverWaiters.removeValue(forKey: waiterId) else { return nil }
            return { waiter.continuation.resume(returning: false) }
        }
        effect?()
    }

    private static func resolveReachedDelivers(_ state: inout State) -> [() -> Void] {
        var effects: [() -> Void] = []
        for (id, waiter) in state.deliverWaiters {
            guard let entry = state.entries[waiter.entryId], entry.taken,
                  state.requestCount >= entry.targetRequestCount else { continue }
            state.deliverWaiters.removeValue(forKey: id)
            effects.append { waiter.continuation.resume(returning: true) }
        }
        return effects
    }
}

/// load ごとに 1 つ作られる事象の通り道。`stop` / `load` の後も同じ channel を指し続ける。
@MainActor
final class EngineChannel {
    private let core = ChannelCore()
    private(set) var stream: AsyncStream<EngineEvent>!

    init() {
        let core = self.core
        stream = AsyncStream(unfolding: { await core.next() }, onCancel: { core.finish() })
    }

    /// 事象を積み、消費者が処理し終えるまで待つ（下位。XCTFail しない）。
    /// ① 取り出し済みで要求回数が目標に達した → true / ② 取り出し済みの後に終了 → true /
    /// ③ 取り出される前に終了（呼んだ時点で終了済みを含む）→ false / ④ timeout → false。
    func deliver(_ event: EngineEvent, timeout: TimeInterval = 1) async -> Bool {
        await core.deliver(event, timeout: timeout)
    }

    /// `deliver` が false なら XCTFail する（取り出される前に終了した channel への送信を黙って成功扱いにしない）。
    func send(
        _ event: EngineEvent,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let delivered = await core.deliver(event, timeout: timeout)
        if !delivered {
            XCTFail("事象 \(event) が処理される前に channel が終了したか、timeout した", file: file, line: line)
        }
    }

    /// stale 注入専用。待たない。
    @discardableResult
    func yield(_ event: EngineEvent) -> YieldResult {
        core.yield(event)
    }

    var hasPendingDeliver: Bool { core.hasPendingDeliver }

    fileprivate func finish() { core.finish() }
}

/// `AudioEngine` の test double。テストは状態（`isLoaded`）を観測し、呼出回数は assert しない。
@MainActor
final class AudioEngineDouble: AudioEngine {
    // helper の既定引数（Swift 5 モードでは nonisolated な文脈で評価される）から生成できるよう、init は隔離しない。
    nonisolated init() {}

    private(set) var isLoaded = false
    /// 設定すると次の `load` の戻り値になる（1 回で消費される）。
    var nextLoadWarning: String?
    /// 現在（直近）の load の channel。後で stop / load されても、取り出した channel は同じものを指す。
    private(set) var currentChannel: EngineChannel?

    func load(url: URL) -> String? {
        currentChannel?.finish()
        currentChannel = EngineChannel()
        isLoaded = true
        let warning = nextLoadWarning
        nextLoadWarning = nil
        return warning
    }

    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func setRate(_ rate: Float) {}

    func stop() {
        isLoaded = false
        currentChannel?.finish()
    }

    var events: AsyncStream<EngineEvent> {
        guard isLoaded, let stream = currentChannel?.stream else {
            return AsyncStream { $0.finish() }
        }
        return stream
    }

    // MARK: テストからの注入（現在の channel へ）

    func send(
        _ event: EngineEvent,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let channel = currentChannel else {
            XCTFail("load されていない engine double へ送信した: \(event)", file: file, line: line)
            return
        }
        await channel.send(event, timeout: timeout, file: file, line: line)
    }
}
