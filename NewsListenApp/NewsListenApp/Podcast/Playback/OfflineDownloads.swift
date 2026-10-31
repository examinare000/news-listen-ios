//
//  OfflineDownloads.swift
//  NewsListenApp
//
//  オフライン保存の use case。取り直し → URL の検査 → 取得 → 保存の手順、
//  同じ id の二重実行の抑止、実行中の id の集合、cancel を持つ。
//

import Foundation
import Combine

enum DownloadReceipt: Equatable { case saved, alreadySaved, alreadyRunning }

enum DownloadFailure: Error, Equatable {
    case api(ApiFailure)
    case invalidSource
    /// 保存の失敗の説明文。文言は呼ぶ側が作る。
    case store(String)
}

@MainActor
final class OfflineDownloads: ObservableObject {
    /// 旧 VM の `DownloadState`（`PodcastViewModel.swift:14-22`）と同じ 3 値。同じ module に同名の型を 2 つ置けないので入れ子で宣言する。
    enum State: Equatable { case notDownloaded, downloading, downloaded }

    @Published private(set) var downloadingIds: Set<String> = []

    private let library: OfflineLibrary
    private let fetchEpisode: (String) async throws -> Episode
    private let downloadAudio: (URL) async throws -> Data
    private var tasks: [String: Task<DownloadReceipt, Error>] = [:]

    init(library: OfflineLibrary,
         fetchEpisode: @escaping (String) async throws -> Episode,
         downloadAudio: @escaping (URL) async throws -> Data) {
        self.library = library
        self.fetchEpisode = fetchEpisode
        self.downloadAudio = downloadAudio
    }

    @discardableResult
    func download(episodeId: String) async throws -> DownloadReceipt {
        if library.has(episodeId) { return .alreadySaved }
        if downloadingIds.contains(episodeId) { return .alreadyRunning }

        // 最初の中断点より前に同期で登録する。Task の中で登録すると、同時に始めた 2 回目が空の集合を見て二重実行になる。
        let task = Task { try await self.run(episodeId) }
        downloadingIds.insert(episodeId)
        tasks[episodeId] = task
        return try await task.value
    }

    func remove(episodeId: String) throws {
        do {
            try library.remove(episodeId)
        } catch {
            throw DownloadFailure.store(error.localizedDescription)
        }
    }

    func removeAll() throws {
        do {
            try library.clearAll()
        } catch {
            throw DownloadFailure.store(error.localizedDescription)
        }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    func state(for episodeId: String) -> State {
        if downloadingIds.contains(episodeId) { return .downloading }
        return library.has(episodeId) ? .downloaded : .notDownloaded
    }

    private func run(_ id: String) async throws -> DownloadReceipt {
        defer {
            downloadingIds.remove(id)
            tasks[id] = nil
        }
        let data: Data
        do {
            guard case .playable(let playable) = try await fetchEpisode(id),
                  let url = URL(string: playable.audioUrl) else {
                throw DownloadFailure.invalidSource
            }
            data = try await downloadAudio(url)
        } catch let failure as ApiFailure {
            throw DownloadFailure.api(failure)
        }
        // cancel を見ない取得が data を返しても保存しない。
        try Task.checkCancellation()
        do {
            try library.save(data, for: id)
        } catch {
            throw DownloadFailure.store(error.localizedDescription)
        }
        return .saved
    }
}

typealias DownloadState = OfflineDownloads.State
