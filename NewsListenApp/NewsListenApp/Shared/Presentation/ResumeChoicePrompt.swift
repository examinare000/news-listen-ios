//
//  ResumeChoicePrompt.swift
//  NewsListenApp
//
//  再開時の確認の見出し・本文・ボタンの文言と時間の書式（shared-sync-14・shared-dec-42）。
//  View はここを読んで配線するだけにし、文言と書式をテストで直接観測できるようにする。
//

import Foundation

enum ResumeChoicePrompt {
    struct Option: Identifiable {
        let selection: ResumeSelection
        let label: String
        var id: String { label }
    }

    static let title = "どちらの位置から続けますか"

    /// ボタンの並び。位置はボタンに付けず、本文で示す。
    static let options: [Option] = [
        Option(selection: .otherDevice, label: "別の端末の位置から"),
        Option(selection: .thisDevice, label: "この端末の位置から"),
    ]

    static func message(otherDeviceSeconds: Double, thisDeviceSeconds: Double) -> String {
        "別の端末: \(clock(otherDeviceSeconds)) ／ この端末: \(clock(thisDeviceSeconds))"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
