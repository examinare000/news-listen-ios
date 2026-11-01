import Combine
import Foundation
import XCTest
import os
@testable import NewsListenApp

// facade テスト（PodcastViewModel 越しに Coordinator・Reporter・保存庫・ダウンロードを観測するテスト）共用の
// 組み立て関数と double。`PlaybackCoordinatorTests` の private な double とは別に持つ（既存テストを動かさないため）。

// MARK: - double

/// 位置の書込・完聴・取得・音声取得の呼出を、呼ばれた順に記録する。
final class EntryGatewayLog: @unchecked Sendable {
    enum Event: Equatable {
        case fetch(String)
        case updatePosition(id: String, seconds: Double)
        case markCompleted(String)
        case downloadAudio(URL)
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Event]())
    var events: [Event] { lock.withLock { $0 } }
    var fetches: [String] { events.compactMap { if case .fetch(let id) = $0 { return id } else { return nil } } }
    var updates: [(id: String, seconds: Double)] {
        events.compactMap { if case .updatePosition(let id, let seconds) = $0 { return (id, seconds) } else { return nil } }
    }
    var marks: [String] { events.compactMap { if case .markCompleted(let id) = $0 { return id } else { return nil } } }
    var downloads: [URL] { events.compactMap { if case .downloadAudio(let url) = $0 { return url } else { return nil } } }

    func record(_ event: Event) { lock.withLock { $0.append(event) } }
}

/// 保留できる `fetchEpisode`。`hold` した id は `release` まで応答を待たせる。
final class HoldableFetch: @unchecked Sendable {
    private struct State {
        var responses: [String: Episode] = [:]
        var failures: [String: Error] = [:]
        var holds: Set<String> = []
        var parked: [String: [CheckedContinuation<Error?, Never>]] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log: EntryGatewayLog

    init(log: EntryGatewayLog) { self.log = log }

    func respond(_ id: String, with episode: Episode) { lock.withLock { $0.responses[id] = episode } }
    func fail(_ id: String, with error: Error) { lock.withLock { $0.failures[id] = error } }
    func hold(_ id: String) { lock.withLock { _ = $0.holds.insert(id) } }

    /// 待ちに入っている呼出の数。
    func parkedCount(_ id: String) -> Int { lock.withLock { $0.parked[id]?.count ?? 0 } }

    func release(_ id: String, throwing error: Error? = nil) {
        let continuation: CheckedContinuation<Error?, Never>? = lock.withLock { state in
            guard var waiting = state.parked[id], !waiting.isEmpty else { return nil }
            let first = waiting.removeFirst()
            state.parked[id] = waiting
            return first
        }
        continuation?.resume(returning: error)
    }

    func fetch(_ id: String) async throws -> Episode {
        log.record(.fetch(id))
        let outcome: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let immediate: Bool = lock.withLock { state in
                if state.holds.contains(id) {
                    state.parked[id, default: []].append(continuation)
                    return false
                }
                return true
            }
            if immediate { continuation.resume(returning: nil) }
        }
        if let outcome { throw outcome }
        let (response, failure) = lock.withLock { ($0.responses[id], $0.failures[id]) }
        if let failure { throw failure }
        guard let response else { throw ApiFailure.unknown(status: 404) }
        return response
    }
}

/// 保留できる `downloadAudio`。
final class HoldableDownload: @unchecked Sendable {
    private struct State {
        var failure: Error?
        var data = Data([1, 2, 3])
        var holding = false
        var parked: [CheckedContinuation<Error?, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let log: EntryGatewayLog

    init(log: EntryGatewayLog) { self.log = log }

    func fail(with error: Error) { lock.withLock { $0.failure = error } }
    func hold() { lock.withLock { $0.holding = true } }
    var parkedCount: Int { lock.withLock { $0.parked.count } }

    func release(throwing error: Error? = nil) {
        let continuation: CheckedContinuation<Error?, Never>? = lock.withLock { state in
            state.parked.isEmpty ? nil : state.parked.removeFirst()
        }
        continuation?.resume(returning: error)
    }

    func download(_ url: URL) async throws -> Data {
        log.record(.downloadAudio(url))
        let outcome: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            let immediate: Bool = lock.withLock { state in
                if state.holding {
                    state.parked.append(continuation)
                    return false
                }
                return true
            }
            if immediate { continuation.resume(returning: nil) }
        }
        if let outcome { throw outcome }
        let (failure, data) = lock.withLock { ($0.failure, $0.data) }
        if let failure { throw failure }
        return data
    }
}

/// Reporter の `now:` に渡す時計。
final class EntryClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 2_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// 接続状態を途中で変えられる `NetworkMonitoring`（`StubNetworkMonitor` は途中変更できない）。
final class MutableNetworkMonitor: NetworkMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>

    init(isOnline: Bool = true) { subject = CurrentValueSubject(isOnline) }

    var isOnline: Bool {
        get { subject.value }
        set { subject.send(newValue) }
    }

    var isOnlinePublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

/// 背景 task の開始・終了と、オンライン・既定速度の可変な環境。
final class EntryEnvironment: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (speed: Float(1.0), began: 0, ended: 0))
    var speed: Float {
        get { lock.withLock { $0.speed } }
        set { lock.withLock { $0.speed = newValue } }
    }
    var backgroundBegan: Int { lock.withLock { $0.began } }
    var backgroundEnded: Int { lock.withLock { $0.ended } }
    func beginBackground() -> () -> Void {
        lock.withLock { $0.began += 1 }
        return { [self] in lock.withLock { $0.ended += 1 } }
    }
}

/// 完聴後の `onCompletionRecorded` の呼出回数。
final class CompletionCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { lock.withLock { $0 } }
    func increment() { lock.withLock { $0 += 1 } }
}

/// 一覧の通信を包み、`GET /podcasts` を 1 回だけ差し替えられる `URLSessionProtocol`。
/// 差し替える一覧は「直前に受け取った一覧」へ、渡した `Podcast` を同じ id は置き換え、無い id は末尾に足した和にする。
/// それ以外の要求は包んだ session へそのまま流す。
///
/// - Important: 一覧の取得が進行中のときに `queueSeed` を呼ばない（差し替えは 1 回だけなので、重なるとどちらの要求が差し替わるか決まらない）。
final class SeedableListSession: URLSessionProtocol, @unchecked Sendable {
    private struct State {
        var list: [Podcast] = []
        var pending: Data?
    }

    private let base: URLSessionProtocol
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(base: URLSessionProtocol) { self.base = base }

    /// 次の `GET /podcasts` の応答を、直前の一覧に `podcasts` を上書き・追加した一覧にする。
    func queueSeed(_ podcasts: [Podcast]) throws {
        var merged = state.withLock { $0.list }
        for podcast in podcasts {
            if let index = merged.firstIndex(where: { $0.id == podcast.id }) {
                merged[index] = podcast
            } else {
                merged.append(podcast)
            }
        }
        let body = try EntryFixture.podcastListJSON(merged)
        state.withLock {
            $0.list = merged
            $0.pending = body
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard (request.httpMethod ?? "GET") == "GET", request.url?.path == "/podcasts" else {
            return try await base.data(for: request)
        }
        if let body = state.withLock({ state -> Data? in
            defer { state.pending = nil }
            return state.pending
        }) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        let (data, response) = try await base.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(PodcastListResponse.self, from: data) {
            state.withLock { $0.list = decoded.podcasts }
        }
        return (data, response)
    }
}

// MARK: - fixture

enum EntryFixture {
    static func content(_ id: String, duration: Int = 300) -> EpisodeContent {
        EpisodeContent(
            id: id, title: "題 \(id)", japaneseIntroText: "導入 \(id)", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: duration,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: [], sourceKind: nil
        )
    }

    static func playable(_ id: String, url: String? = nil, serverPosition: Double = 0, duration: Int = 300) -> Episode {
        .playable(PlayableEpisode(
            content: content(id, duration: duration),
            audioUrl: url ?? "https://cdn.example.com/\(id).mp3",
            serverPosition: serverPosition
        )!)
    }

    /// 一覧の行（通信のデータモデル）。
    static func podcast(
        _ id: String,
        status: String = "completed",
        audioUrl: String? = nil,
        errorMessage: String? = nil,
        playbackPositionSeconds: Double = 0,
        durationSeconds: Int = 300
    ) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: audioUrl ?? "https://cdn.example.com/\(id).mp3", title: "題 \(id)",
            japaneseIntroText: "導入 \(id)",
            durationSeconds: durationSeconds, createdAt: "2026-05-31T06:00:00Z", status: status,
            errorMessage: errorMessage, playbackPositionSeconds: playbackPositionSeconds, segments: nil
        )
    }

    /// 一覧の JSON（`GET /podcasts` の応答）。facade の `loadPodcasts()` に読ませる。
    static func podcastListJSON(_ podcasts: [Podcast]) throws -> Data {
        try JSONEncoder().encode(PodcastListResponse(podcasts: podcasts))
    }
}

// MARK: - 組み立て

/// facade（`PodcastViewModel`）・Coordinator・Reporter・保存庫・ダウンロード・double を 1 組で組み立てる。
@MainActor
final class PlaybackEntryRig {
    let engine = AudioEngineDouble()
    let spy: NowPlayingCenterSpy
    let library: OfflineLibrary
    let gateway = EntryGatewayLog()
    let fetch: HoldableFetch
    let download: HoldableDownload
    let network: MutableNetworkMonitor
    let clock = EntryClock()
    let environment = EntryEnvironment()
    let completions = CompletionCounter()
    let reporter: PositionReporter
    let coordinator: PlaybackCoordinator
    let downloads: OfflineDownloads
    let catalog: EpisodeCatalog
    let viewModel: PodcastViewModel
    private let listSession: SeedableListSession
    private let ownsCatalog: Bool

    /// - Parameters:
    ///   - lockScreenSubtitle: ロック画面の副題の作り方（既定は難易度コードに接頭辞を付ける）。
    ///   - session: 一覧の取得に使う URLSession（既定は空 JSON を返す）。
    ///   - catalog: 外から渡す一覧（渡した rig では `seed` を使わない）。既定は `session` の通信から組む。
    ///   - onPositionSaved: 位置の保存の応答を受けたときの処理（既定は何もしない）。合成 root と同じ形の closure を渡せる。
    ///   - updatePosition: 位置の書込の応答を差し替える（既定は書込を記録して同じ位置の `Episode` を返す）。
    ///   - markCompleted: 完聴の記録を記録した後に追加で走らせる処理（実 `APIClient` へ流して要求を観測する用途）。
    ///   - onCompletion: 完聴の記録が済んだ後（`completions` を数える前）に走らせる処理。
    init(
        online: Bool = true,
        defaultSpeed: Float = 1.0,
        lockScreenSubtitle: @escaping (_ difficulty: String) -> String = { "sub:\($0)" },
        session: URLSessionProtocol? = nil,
        catalog: EpisodeCatalog? = nil,
        onPositionSaved: ((Episode) -> Void)? = nil,
        updatePosition: ((_ id: String, _ seconds: Double) async throws -> Episode)? = nil,
        markCompleted: ((_ id: String) async throws -> Void)? = nil,
        onCompletion: (@MainActor () async -> Void)? = nil
    ) {
        let spy = NowPlayingCenterSpy()
        self.spy = spy
        let gateway = self.gateway
        let fetch = HoldableFetch(log: gateway)
        let download = HoldableDownload(log: gateway)
        self.fetch = fetch
        self.download = download
        let network = MutableNetworkMonitor(isOnline: online)
        self.network = network
        let environment = self.environment
        let clock = self.clock
        let completions = self.completions
        environment.speed = defaultSpeed
        let library = OfflineLibrary(
            store: .live(cacheManager: AudioCacheManager(fileManager: PodcastViewModelTests.MockFileManager())))
        library.bind(subject: subjectA)
        self.library = library

        let reporter = PositionReporter(
            updatePosition: { id, seconds in
                gateway.record(.updatePosition(id: id, seconds: seconds))
                if let updatePosition { return try await updatePosition(id, seconds) }
                return EntryFixture.playable(id, serverPosition: seconds)
            },
            markCompleted: { id in
                gateway.record(.markCompleted(id))
                if let markCompleted { try await markCompleted(id) }
            },
            onPositionSaved: { episode in onPositionSaved?(episode) },
            onCompletionRecorded: {
                // 呼出回数を数える前に走らせる。回数を待ったテストは、この処理も済んだ後を観測できる。
                await onCompletion?()
                completions.increment()
            },
            beginBackgroundTask: { environment.beginBackground() },
            now: { clock.now })
        self.reporter = reporter

        let coordinator = PlaybackCoordinator(
            engine: engine,
            nowPlayingCenter: spy,
            library: library,
            reporter: reporter,
            fetchEpisode: { id in try await fetch.fetch(id) },
            isOnline: { network.isOnline },
            defaultSpeed: { environment.speed },
            lockScreenSubtitle: lockScreenSubtitle,
            beginBackgroundTask: { environment.beginBackground() })
        self.coordinator = coordinator

        let downloads = OfflineDownloads(
            library: library,
            fetchEpisode: { id in try await fetch.fetch(id) },
            downloadAudio: { url in try await download.download(url) },
            currentSubject: { subjectA })
        self.downloads = downloads

        let listSession = SeedableListSession(
            base: session ?? MockURLSession(data: Data(#"{"podcasts":[]}"#.utf8), statusCode: 200))
        self.listSession = listSession
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: listSession)
        ownsCatalog = catalog == nil
        let resolvedCatalog = catalog ?? EpisodeCatalog(gateway: CatalogGateway.live(apiClient: client))
        self.catalog = resolvedCatalog
        viewModel = PodcastViewModel(
            apiClient: client,
            catalog: resolvedCatalog,
            coordinator: coordinator,
            reporter: reporter,
            library: library,
            downloads: downloads,
            networkMonitor: network,
            defaultSpeed: { environment.speed })
    }

    /// 保存庫に音声を置く（キャッシュ済みとして解決される）。
    func cached(_ id: String) throws {
        try library.save(Data([1, 2, 3]), for: id, subject: subjectA)
    }

    /// 取得の応答を登録する。
    func serve(_ episode: Episode) {
        if case .playable(let playable) = episode { fetch.respond(playable.content.id, with: episode) }
    }

    /// 一覧（catalog）に `podcasts` を入れる。同じ id は置き換え、無い id は末尾に足す。
    /// 一覧の取得が進行中のときに呼ばない。`catalog:` を渡した rig では使えない。
    func seed(_ podcasts: [Podcast]) async throws {
        guard ownsCatalog else {
            XCTFail("catalog を外から渡した rig では seed を使わない")
            return
        }
        try listSession.queueSeed(podcasts)
        try await catalog.reload()
    }

    /// キャッシュ済みとして開始し、`ready`（playing）まで進める。一覧に無い id は先に入れる。
    func play(_ id: String, duration: Int = 300) async throws {
        try cached(id)
        if catalog.episode(id: id) == nil {
            try await seed([EntryFixture.podcast(id, durationSeconds: duration)])
        }
        await viewModel.startEpisode(episodeId: id)
        await engine.send(.ready)
    }
}
