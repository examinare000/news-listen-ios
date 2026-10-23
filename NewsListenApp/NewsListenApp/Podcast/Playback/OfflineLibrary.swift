//
//  OfflineLibrary.swift
//  NewsListenApp
//
//  保存済み音声の集合と保存庫 port（`AudioFileStore`。closure の束）。
//  ファイルの実体が正本で、`savedIds` はその写し。
//

import Foundation
import Combine

struct AudioFileStore {
    let url: (String) -> URL?
    let exists: (String) -> Bool
    let write: (Data, String) throws -> Void
    let remove: (String) throws -> Void
    let removeAll: () throws -> Void
    let size: () -> Int64
}

@MainActor
final class OfflineLibrary: ObservableObject {
    @Published private(set) var savedIds: Set<String> = []
    private let store: AudioFileStore

    nonisolated init(store: AudioFileStore) {
        self.store = store
    }

    func save(_ data: Data, for id: String) throws {
        try store.write(data, id)
        savedIds.insert(id)
    }

    func has(_ id: String) -> Bool {
        store.exists(id)
    }

    func url(_ id: String) -> URL? {
        store.url(id)
    }

    func remove(_ id: String) throws {
        do {
            try store.remove(id)
        } catch {
            resyncWithStore()
            throw error
        }
        savedIds.remove(id)
    }

    func clearAll() throws {
        do {
            try store.removeAll()
        } catch {
            resyncWithStore()
            throw error
        }
        savedIds = []
    }

    func usage() -> Int64 {
        store.size()
    }

    func refresh(candidateIds: [String]) {
        savedIds = Set(candidateIds.filter(has))
    }

    private func resyncWithStore() {
        savedIds = savedIds.filter(has)
    }
}
