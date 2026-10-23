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
            url: { id in cacheManager.isCached(id) ? cacheManager.cachedURL(for: id) : nil },
            exists: { id in cacheManager.isCached(id) },
            write: { data, id in try cacheManager.cache(data, for: id) },
            remove: { id in try cacheManager.remove(id) },
            removeAll: { try cacheManager.clearCache() },
            size: { cacheManager.cacheSize() }
        )
    }
}
