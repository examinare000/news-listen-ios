//
//  PositionRecordStore.swift
//  NewsListenApp
//
//  端末の位置の記録を読み書きする port（closure の束）。保存先は adapter が決める。
//

import Foundation

struct PositionRecordStore {
    let read: (SubjectKey) -> [PositionRecord]
    let write: (SubjectKey, [PositionRecord]) throws -> Void
    let removeSubject: (SubjectKey) throws -> Void
    let reclaim: (SubjectKey?) throws -> Void
}
