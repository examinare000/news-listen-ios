//
//  PositionRecordFiles.swift
//  NewsListenApp
//
//  端末の位置の記録を、主体ごとの JSON ファイル（`<directory>/<SubjectKey.rawValue>.json`）へ保存する adapter。
//  ファイル名は `SubjectKey` が許す文字だけなので、パスをたどる入力は作れない。
//

import Foundation

final class PositionRecordFiles {
    private static let currentVersion = 1

    /// 保存の形。時刻は整数ミリ秒。時刻の無い記録は読むときに捨てる。
    private struct StoredFile: Codable {
        let version: Int
        let records: [StoredRecord]
    }

    private struct StoredRecord: Codable {
        let episodeId: String
        let seconds: Double
        let recordedAtMilliseconds: Int64?
        let isSent: Bool
    }

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private func fileURL(_ subject: SubjectKey) -> URL {
        directory.appendingPathComponent("\(subject.rawValue).json")
    }

    /// 無い・読めない・版の違うファイルは空を返す（旧い形を返さない。shared-dec-32）。
    func read(_ subject: SubjectKey) -> [PositionRecord] {
        guard let data = try? Data(contentsOf: fileURL(subject)),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              file.version == Self.currentVersion
        else { return [] }
        return file.records.compactMap { stored in
            guard let milliseconds = stored.recordedAtMilliseconds else { return nil }
            return PositionRecord(
                subject: subject, episodeId: stored.episodeId, seconds: stored.seconds,
                recordedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000), isSent: stored.isSent)
        }
    }

    func write(_ records: [PositionRecord], for subject: SubjectKey) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = StoredFile(
            version: Self.currentVersion,
            records: records.map {
                StoredRecord(
                    episodeId: $0.episodeId, seconds: $0.seconds,
                    recordedAtMilliseconds: Int64(($0.recordedAt.timeIntervalSince1970 * 1000).rounded()),
                    isSent: $0.isSent)
            })
        try JSONEncoder().encode(file).write(to: fileURL(subject), options: .atomic)
    }

    func removeSubject(_ subject: SubjectKey) throws {
        let url = fileURL(subject)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func reclaim(keeping: SubjectKey?) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let kept = keeping.map { "\($0.rawValue).json" }
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) where name != kept {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
