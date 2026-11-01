//
//  AudioFileStore+Live.swift
//  NewsListenApp
//
//  `AudioFileStore` を `AudioCacheManager` の操作から組む adapter。具象は引数で受け、ここでは作らない。
//

import Foundation

extension AudioFileStore {
    static func live(cacheManager: AudioCacheManager) -> AudioFileStore {
        AudioFileStore(
            url: { (id: String, subject: SubjectKey) in
                cacheManager.isCached(id, subject: subject) ? cacheManager.cachedURL(for: id, subject: subject) : nil
            },
            exists: { (id: String, subject: SubjectKey) in cacheManager.isCached(id, subject: subject) },
            write: { (data: Data, id: String, subject: SubjectKey) in try cacheManager.cache(data, for: id, subject: subject) },
            remove: { (id: String, subject: SubjectKey) in try cacheManager.remove(id, subject: subject) },
            removeSubject: { (subject: SubjectKey) in try cacheManager.removeSubject(subject) },
            size: { (subject: SubjectKey) in cacheManager.cacheSize(subject: subject) },
            reclaim: { (keeping: SubjectKey?) in try cacheManager.reclaim(keeping: keeping) }
        )
    }
}
