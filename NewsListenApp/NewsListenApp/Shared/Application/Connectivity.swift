//
//  Connectivity.swift
//  NewsListenApp
//
//  ネットワーク接続状態の port。実装（`NetworkMonitor`・`StubNetworkMonitor`）は `Networking/` に置く。
//

import Foundation
import Combine

/// ネットワーク接続状態を提供するプロトコル。
///
/// 唯一の本番実装 ``NetworkMonitor`` が `@MainActor`（`ObservableObject`/`@Published`）であり、
/// 利用側（``PodcastViewModel`` / ``PodcastView``）も `@MainActor` 文脈で `isOnline` を参照する。
/// Swift 6 では `@MainActor` 型の非分離プロトコルへの適合が「分離付き適合」となり非分離文脈から
/// 使えないため、プロトコル自体を `@MainActor` にして適合・利用の分離を揃える（要件 #32）。
@MainActor
protocol NetworkMonitoring {
    /// ネットワークがオンラインかどうか。
    var isOnline: Bool { get }
    /// `isOnline` の変化を購読するためのパブリッシャ（issue #54）。
    ///
    /// ViewModel がオフラインバナー等の表示に反応的に追従できるよう、値型実装（``StubNetworkMonitor``）も
    /// 含めてプロトコル要件とする。`StubNetworkMonitor` は変化しない値の単発発行で足りる（テスト用途のため）。
    var isOnlinePublisher: AnyPublisher<Bool, Never> { get }
}
