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
    let url: (String, SubjectKey) -> URL?
    let exists: (String, SubjectKey) -> Bool
    let write: (Data, String, SubjectKey) throws -> Void
    let remove: (String, SubjectKey) throws -> Void
    let removeSubject: (SubjectKey) throws -> Void
    let size: (SubjectKey) -> Int64
    let reclaim: (SubjectKey?) throws -> Void
}

@MainActor
final class OfflineLibrary: ObservableObject {
    enum SaveError: LocalizedError, Equatable {
        case cacheDisabled

        var errorDescription: String? { "オフライン保存を利用できません" }
    }

    @Published private(set) var savedIds: Set<String> = []
    private let store: AudioFileStore
    private var boundSubject: SubjectKey?

    nonisolated init(store: AudioFileStore) {
        self.store = store
    }

    func bind(subject: SubjectKey?) {
        boundSubject = subject
        savedIds = []
    }

    /// 書込先は渡された主体で決める。離脱で束縛が外れた後に完了した書き込みも、その主体のディレクトリに入る。
    func save(_ data: Data, for id: String, subject: SubjectKey?) throws {
        guard let subject else { throw SaveError.cacheDisabled }
        try store.write(data, id, subject)
        if subject == boundSubject { savedIds.insert(id) }
    }

    func has(_ id: String) -> Bool {
        guard let boundSubject else { return false }
        return store.exists(id, boundSubject)
    }

    func url(_ id: String) -> URL? {
        guard let boundSubject else { return nil }
        return store.url(id, boundSubject)
    }

    func remove(_ id: String) throws {
        guard let boundSubject else { return }
        do {
            try store.remove(id, boundSubject)
        } catch {
            resyncWithStore()
            throw error
        }
        savedIds.remove(id)
    }

    func remove(subject: SubjectKey?) throws {
        guard let subject else { return }
        do {
            try store.removeSubject(subject)
        } catch {
            resyncWithStore()
            throw error
        }
        if subject == boundSubject { savedIds = [] }
    }

    func reclaim(keeping: SubjectKey?) throws {
        try store.reclaim(keeping)
        savedIds = savedIds.filter(has)
    }

    func usage() -> Int64 {
        guard let boundSubject else { return 0 }
        return store.size(boundSubject)
    }

    func refresh(candidateIds: [String]) {
        savedIds = Set(candidateIds.filter(has))
    }

    private func resyncWithStore() {
        savedIds = savedIds.filter(has)
    }
}
