import Combine
import XCTest
@testable import NewsListenApp

// `FeedViewModelTests`・`StarredViewModelTests` の Given 用の補助。
// VM の一覧は `private(set)` で外から書けないので、最初の 1 回の取得だけ `articles` を返す gateway で Given を作る。

/// `isOnline` を書けるテスト専用のモニタ（`StubNetworkMonitor` は値が変わらない）。
@MainActor
final class SwitchableNetworkMonitor: NetworkMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>

    init(isOnline: Bool = true) {
        subject = CurrentValueSubject(isOnline)
    }

    var isOnline: Bool {
        get { subject.value }
        set { subject.send(newValue) }
    }

    var isOnlinePublisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }
}

/// 最初の 1 回だけ値を渡す箱。
@MainActor
private final class OneShot<Value> {
    private var value: Value?

    init(_ value: Value?) {
        self.value = value
    }

    func take() -> Value? {
        defer { value = nil }
        return value
    }
}

private struct GivenMismatch: Error {}

/// `articles` を渡すと、最初の 1 回の `fetchFeed` だけ `articles` を返し、以降は実物の `.live(client:)` に委ねる。
/// Given は `curation.reload()` で作るので、VM のオフライン判定は通らない。
@MainActor
func makeFeedViewModel(
    articles: [ArticleCardModel]? = nil,
    client: APIClient,
    undoGracePeriod: Duration = .seconds(4),
    networkMonitor: NetworkMonitoring = NetworkMonitor()
) async throws -> (FeedViewModel, FeedCuration) {
    let live = CurationGateway.live(client: { client })
    let seed = OneShot(articles)
    let gateway = CurationGateway(
        fetchFeed: {
            if let given = await seed.take() { return given }
            return try await live.fetchFeed()
        },
        star: live.star,
        dismiss: live.dismiss,
        fetchStarred: live.fetchStarred,
        unstar: live.unstar,
        fetchAllowance: live.fetchAllowance
    )
    let curation = FeedCuration(gateway: gateway, undoGracePeriod: undoGracePeriod, currentSubject: { nil })
    if articles != nil {
        try await curation.reload()
    }
    let vm = FeedViewModel(curation: curation, networkMonitor: networkMonitor)
    return (vm, curation)
}

/// `articles` を渡すと、最初の 1 回の `fetchStarred` だけ `articles` を返し、以降は実物の `.live(client:)` に委ねる。
/// Given は `loadStarred()` で作ってから `online` に切り替える（オフラインでも記事が残る状態を作れる）。
@MainActor
func makeStarredViewModel(
    articles: [ArticleCardModel]? = nil,
    client: APIClient,
    online: Bool = true
) async throws -> StarredViewModel {
    let live = CurationGateway.live(client: { client })
    let seed = OneShot(articles)
    let gateway = CurationGateway(
        fetchFeed: live.fetchFeed,
        star: live.star,
        dismiss: live.dismiss,
        fetchStarred: {
            if let given = await seed.take() { return given }
            return try await live.fetchStarred()
        },
        unstar: live.unstar,
        fetchAllowance: live.fetchAllowance
    )
    let monitor = SwitchableNetworkMonitor(isOnline: true)
    let vm = StarredViewModel(starred: StarredArticles(gateway: gateway), networkMonitor: monitor)
    if let articles {
        await vm.loadStarred()
        guard vm.articles == articles else { throw GivenMismatch() }
    }
    monitor.isOnline = online
    // VM は main キュー経由で `isOnline` を受けるので、反映まで待つ。
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while vm.isOnline != online, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard vm.isOnline == online else { throw GivenMismatch() }
    return vm
}
