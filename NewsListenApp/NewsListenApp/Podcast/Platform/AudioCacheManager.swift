//
//  AudioCacheManager.swift
//  NewsListenApp
//
//  Podcast の音声をローカルディスクにキャッシュし、オフライン再生に対応する。
//  Path traversal 防御を実装し、不正な id は検証段階で排除する。
//

import Foundation

/// 音声キャッシュで発生しうるエラー。
enum AudioCacheError: LocalizedError {
    /// Podcast ID が不正形式（英数・ハイフン・アンダースコア以外の文字を含む）。
    case invalidId

    var errorDescription: String? {
        switch self {
        case .invalidId: return "Invalid podcast ID format"
        }
    }
}

/// Podcast 音声のローカルキャッシュを管理する。
///
/// `Caches/NewsListenApp/audio/{主体キー}/{id}.mp3` にキャッシュを保存する。主体ごとにディレクトリを分け、
/// 他の主体の path には触れない。
/// 安全性のため、id は `[A-Za-z0-9_-]` のみ許可し、path traversal を防ぐ。
final class AudioCacheManager {
    /// 主体別ディレクトリの親（`Caches/NewsListenApp/audio`）。
    private let audioDirectory: URL
    /// 平置き時代のキャッシュ置き場。移行せず、見つけたら消す。
    private let legacyDirectory: URL
    /// ファイルマネージャ（テスト注入可能）。
    private let fileManager: FileManagerProtocol

    /// マネージャを生成する。
    /// - Parameter fileManager: ファイルマネージャ（既定: `FileManager.default`）。
    init(fileManager: FileManagerProtocol = FileManager.default) {
        self.fileManager = fileManager
        let root = fileManager.cachesDirectory().appendingPathComponent("NewsListenApp")
        self.audioDirectory = root.appendingPathComponent("audio")
        self.legacyDirectory = root.appendingPathComponent("audio-cache")
    }

    /// 指定 Podcast ID のキャッシュ URL を返す（存在有無は問わない）。
    func cachedURL(for id: String, subject: SubjectKey) -> URL {
        subjectDirectory(subject).appendingPathComponent("\(id).mp3")
    }

    /// 指定 Podcast ID のキャッシュが存在するかどうか。
    func isCached(_ id: String, subject: SubjectKey) -> Bool {
        fileManager.fileExists(atPath: cachedURL(for: id, subject: subject).path)
    }

    /// 音声データを主体のディレクトリへ保存する（既存ファイルは上書き）。
    /// - Throws: `AudioCacheError.invalidId` if id is invalid, or I/O errors.
    func cache(_ data: Data, for id: String, subject: SubjectKey) throws {
        try validateId(id)
        try ensureDirectory(subjectDirectory(subject))
        try fileManager.write(data, to: cachedURL(for: id, subject: subject))
    }

    /// キャッシュを削除する（存在しない場合は no-op・冪等）。
    /// - Throws: I/O errors on removal failure.
    func remove(_ id: String, subject: SubjectKey) throws {
        try validateId(id)
        let url = cachedURL(for: id, subject: subject)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// 主体のディレクトリ直下の全ファイルサイズ合計（バイト）。
    func cacheSize(subject: SubjectKey) -> Int64 {
        let directory = subjectDirectory(subject)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        return names.reduce(Int64(0)) { total, name in
            total + (fileManager.fileSize(atPath: directory.appendingPathComponent(name).path) ?? 0)
        }
    }

    /// 主体のディレクトリを削除する（存在しない場合は no-op・冪等）。
    /// - Throws: I/O errors on removal failure.
    func removeSubject(_ subject: SubjectKey) throws {
        let directory = subjectDirectory(subject)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// `keeping` 以外の主体のディレクトリと旧キャッシュ置き場を削除する。`keeping` が nil なら全主体を削除する。
    /// 旧置き場の削除は `audio/` の列挙の成否に依存しない。冪等。
    /// - Throws: 削除の I/O エラー。
    func reclaim(keeping: SubjectKey?) throws {
        if let names = try? fileManager.contentsOfDirectory(atPath: audioDirectory.path) {
            for name in names where name != keeping?.rawValue {
                try fileManager.removeItem(at: audioDirectory.appendingPathComponent(name))
            }
        }
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            try fileManager.removeItem(at: legacyDirectory)
        }
    }

    // MARK: - Private

    private func subjectDirectory(_ subject: SubjectKey) -> URL {
        audioDirectory.appendingPathComponent(subject.rawValue)
    }

    /// ID が安全形式（英数・ハイフン・アンダースコアのみ）かどうかを検証する。
    /// - Throws: `AudioCacheError.invalidId` if invalid.
    private func validateId(_ id: String) throws {
        let validCharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard id.unicodeScalars.allSatisfy({ validCharSet.contains($0) }), !id.isEmpty else {
            throw AudioCacheError.invalidId
        }
    }

    /// ディレクトリが存在しなければ作成する。
    private func ensureDirectory(_ directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }
}
