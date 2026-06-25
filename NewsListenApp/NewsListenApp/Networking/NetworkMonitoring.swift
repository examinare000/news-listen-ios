//
//  NetworkMonitoring.swift
//  NewsListenApp
//
//  ネットワーク接続状態を監視するための抽象と実装。
//

import Foundation
import Combine
import Network

/// ネットワーク接続状態を提供するプロトコル。
protocol NetworkMonitoring {
    /// ネットワークがオンラインかどうか。
    var isOnline: Bool { get }
}

/// `Network.framework` を使用してネットワーク接続状態を監視する。
///
/// `@MainActor` + `@Published` で SwiftUI ビューから購読可能。
@MainActor
final class NetworkMonitor: ObservableObject, NetworkMonitoring {
    /// ネットワークがオンラインかどうか（初期値: `true`）。
    @Published private(set) var isOnline = true

    /// 内部的にパスを監視する NWPathMonitor。
    private let pathMonitor: NWPathMonitor
    /// 監視用のディスパッチキュー。
    private let queue = DispatchQueue(label: "com.newslisten.networkmonitor")

    /// 初期化する。
    ///
    /// `nonisolated` にして SwiftUI ビューのデフォルト引数（同期 nonisolated 文脈）から
    /// 生成できるようにする。`@Published isOnline` の更新は `DispatchQueue.main` 経由のため安全。
    nonisolated init() {
        self.pathMonitor = NWPathMonitor()
        startMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    /// パス監視を開始する。
    nonisolated private func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: queue)
    }
}

/// テスト用のスタブ。接続状態を手動で操作できる。
struct StubNetworkMonitor: NetworkMonitoring {
    /// ネットワークがオンラインかどうか。
    var isOnline: Bool

    /// 初期化する。
    /// - Parameter isOnline: ネットワークの接続状態。既定: `true`。
    init(isOnline: Bool = true) {
        self.isOnline = isOnline
    }
}
