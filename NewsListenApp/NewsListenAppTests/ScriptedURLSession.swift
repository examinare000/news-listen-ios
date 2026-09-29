import Foundation
import os
@testable import NewsListenApp

/// method + path ごとに「即時応答」か「保留」を指定できる `URLSessionProtocol` の test double。
///
/// I-S2 の主体照合（`AppState` の主体ガード表・`SubjectStamp`）テストで、await をまたぐ競合
/// （前の主体の応答が後から届く／進行中に別の主体が確立する）を決定論的に再現するために使う
/// （spec.md §5.5「共通 double」）。全リクエストを一律に止める形は使わない
/// （`logout()` 内の別 path が止まってデッドロックするため。同 spec 節）。
///
/// - 保留したリクエストは `release(method:path:status:body:)` を呼ぶまで返らない。
/// - `waitUntilRequested(method:path:)` で到着を待てる。
/// - 保留中に呼出元の Task がキャンセルされたら `URLError(.cancelled)` を投げ、
///   `onCancel` の中で同期に `cancelledRequests` へ記録する（cancel() を呼んだ Task から
///   戻った時点で観測できる。改訂 4・T-T14-21 用）。
/// - 未設定（`configure`/`configurePending` を呼んでいない）の method + path は、即時 200・
///   空 JSON `{}` を返す（明示的に保留させたいものだけ `configurePending` する。デッドロック回避）。
final class ScriptedURLSession: URLSessionProtocol, @unchecked Sendable {

    private struct Key: Hashable {
        let method: String
        let path: String
    }

    private enum ConfiguredResponse {
        case immediate(status: Int, body: Data)
        case pending
    }

    private struct State {
        var responses: [Key: ConfiguredResponse] = [:]
        var pendingContinuations: [Key: [CheckedContinuation<(Data, URLResponse), Error>]] = [:]
        var arrivalContinuations: [Key: [CheckedContinuation<Void, Never>]] = [:]
        var arrivedKeys: Set<Key> = []
        var sentRequests: [URLRequest] = []
        var cancelledRequests: [(method: String, path: String)] = []

        /// 到着を記録し、`waitUntilRequested` の待ち手を resume する。呼び出し側のロック内で使う。
        mutating func markArrived(_ key: Key) {
            arrivedKeys.insert(key)
            let waiters = arrivalContinuations[key] ?? []
            arrivalContinuations[key] = []
            for waiter in waiters { waiter.resume() }
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// 送信されたリクエストを到着順に返す（読み取り専用のスナップショット）。
    var sentRequests: [URLRequest] { lock.withLock { $0.sentRequests } }

    /// 保留中にキャンセルされたリクエストの (method, path) を到着順に返す。
    var cancelledRequests: [(method: String, path: String)] { lock.withLock { $0.cancelledRequests } }

    /// 指定 method + path に即時応答（status・body）を設定する。
    func configure(method: String, path: String, status: Int, body: Data = Data()) {
        lock.withLock { $0.responses[Key(method: method, path: path)] = .immediate(status: status, body: body) }
    }

    /// 指定 method + path を保留状態にする。`release` を呼ぶまで呼出元は suspend したままになる。
    func configurePending(method: String, path: String) {
        lock.withLock { $0.responses[Key(method: method, path: path)] = .pending }
    }

    /// 指定 method + path のリクエストが到着するまで待つ。既に到着済みなら即座に返る。
    func waitUntilRequested(method: String, path: String) async {
        let key = Key(method: method, path: path)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyArrived: Bool = lock.withLock { state in
                if state.arrivedKeys.contains(key) { return true }
                state.arrivalContinuations[key, default: []].append(continuation)
                return false
            }
            if alreadyArrived { continuation.resume() }
        }
    }

    /// 保留中のリクエストを指定の status・body で解放する。保留が無ければ何もしない。
    func release(method: String, path: String, status: Int, body: Data = Data()) {
        let key = Key(method: method, path: path)
        let waiters: [CheckedContinuation<(Data, URLResponse), Error>] = lock.withLock { state in
            let existing = state.pendingContinuations[key] ?? []
            state.pendingContinuations[key] = []
            return existing
        }
        guard !waiters.isEmpty else { return }
        let url = URL(string: "https://scripted.example.com\(path)")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        for waiter in waiters {
            waiter.resume(returning: (body, response))
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let key = Key(method: method, path: path)

        // 到着通知（`waitUntilRequested` の待ち手を resume）は、`.pending` の場合は保留登録と
        // 同一ロック区間で行う（下記）。別区間にすると「到着通知 → テストが release →
        // 保留登録」の順に走ったとき release が保留無しとして捨てられ、continuation が
        // 永遠に resume されない（lost wakeup。2026-09-30 CI run 36511216822 で 6 時間ハング）。
        let configured: ConfiguredResponse? = lock.withLock { state in
            state.sentRequests.append(request)
            let response = state.responses[key]
            if case .pending = response { return response }
            state.markArrived(key)
            return response
        }

        switch configured {
        case .immediate(let status, let body):
            let url = request.url!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        case .none:
            // 未設定の method + path は即時 200・空 JSON を返す（デッドロック回避。上記コメント参照）。
            let url = request.url!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        case .pending:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    // 保留登録と到着通知を同一ロック区間で行う（上記コメント参照）。
                    lock.withLock { state in
                        state.pendingContinuations[key, default: []].append(continuation)
                        state.markArrived(key)
                    }
                }
            } onCancel: {
                // 同期に記録する: cancel() を呼んだ Task から戻った時点で observer が
                // `cancelledRequests` を読めるようにする（T-T14-21・PM-19）。
                let toResume: CheckedContinuation<(Data, URLResponse), Error>? = lock.withLock { state in
                    state.cancelledRequests.append((method: method, path: path))
                    guard var pending = state.pendingContinuations[key], !pending.isEmpty else { return nil }
                    let first = pending.removeFirst()
                    state.pendingContinuations[key] = pending
                    return first
                }
                toResume?.resume(throwing: URLError(.cancelled))
            }
        }
    }
}
