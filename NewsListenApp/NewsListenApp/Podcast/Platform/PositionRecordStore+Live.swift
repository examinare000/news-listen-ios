//
//  PositionRecordStore+Live.swift
//  NewsListenApp
//
//  `PositionRecordStore` を `PositionRecordFiles` の操作から組む adapter。具象は引数で受け、ここでは作らない。
//

import Foundation

extension PositionRecordStore {
    static func live(files: PositionRecordFiles) -> PositionRecordStore {
        PositionRecordStore(
            read: { (subject: SubjectKey) in files.read(subject) },
            write: { (subject: SubjectKey, records: [PositionRecord]) in try files.write(records, for: subject) },
            removeSubject: { (subject: SubjectKey) in try files.removeSubject(subject) },
            reclaim: { (keeping: SubjectKey?) in try files.reclaim(keeping: keeping) }
        )
    }
}
