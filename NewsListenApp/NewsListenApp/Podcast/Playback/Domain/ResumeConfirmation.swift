//
//  ResumeConfirmation.swift
//  NewsListenApp
//
//  再開時の確認が要るかの判定と、確認の選択の語彙（domain）。ADR-109 決定 11。
//

import Foundation

/// 確認が出ている間に持ち越す、確認を出した時点の 2 つの位置（選択まで読み直さない）。
struct ResumeChoice: Equatable {
    let episodeId: String
    let thisDeviceSeconds: Double
    let otherDeviceSeconds: Double
}

enum ResumeSelection: Equatable {
    case otherDevice
    case thisDevice
}

enum ResumeConfirmation {
    static let thresholdSeconds = 15.0

    /// 2 つの位置が閾値以上離れているときだけ確認を返す。別の端末が進めていても戻していても同じ。
    static func choice(episodeId: String, thisDeviceSeconds: Double, otherDeviceSeconds: Double) -> ResumeChoice? {
        guard abs(otherDeviceSeconds - thisDeviceSeconds) >= thresholdSeconds else { return nil }
        return ResumeChoice(
            episodeId: episodeId, thisDeviceSeconds: thisDeviceSeconds, otherDeviceSeconds: otherDeviceSeconds)
    }
}
