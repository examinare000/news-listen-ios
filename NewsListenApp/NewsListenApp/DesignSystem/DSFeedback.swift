//
//  DSFeedback.swift
//  NewsListenApp
//
//  ADR-088 の音・触覚語彙を一元化する。
//

import AudioToolbox
import SwiftUI
import UIKit

/// Editorial な操作フィードバックを 5 語彙へ限定する。
enum DSFeedbackVocabulary: Hashable {
    case correct
    case incorrect
    case achievement
    case streakUp
    case swipeConfirm
}

/// 効果音・ハプティクスの端末ローカル設定と発火間隔を一元管理する。
@MainActor
final class DSFeedback {
    static let shared = DSFeedback()

    /// AppStorage キーの一元化（Settings 画面と共有）。
    static let sfxEnabledKey = "sfx_enabled"
    static let hapticsEnabledKey = "haptics_enabled"

    @AppStorage(DSFeedback.sfxEnabledKey) private var sfxEnabled = true
    @AppStorage(DSFeedback.hapticsEnabledKey) private var hapticsEnabled = true

    /// 同一語彙の連打で Editorial の静けさを損なわないよう、単調増加時計で 300ms 間引く。
    private var lastPlayedAt: [DSFeedbackVocabulary: TimeInterval] = [:]
    private let minimumInterval: TimeInterval = 0.3

    /// テスト用：最後に play() された語彙を記録（本番では不使用）。
    /// テスト内でリセット可能にするため internal(set)。
    internal(set) var lastPlayedVocabulary: DSFeedbackVocabulary?

    private init() {}

    func play(_ vocabulary: DSFeedbackVocabulary) {
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastPlayedAt[vocabulary],
           now - previous < minimumInterval {
            return
        }
        lastPlayedAt[vocabulary] = now
        lastPlayedVocabulary = vocabulary

        if hapticsEnabled, let style = impactStyle(for: vocabulary) {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred()
        }
        // 音は correct（正答の肯定）と streakUp（継続祝福）の 2 語彙のみ。
        // ADR-088: iOS システム音の制約により、他の語彙は触覚で性格を表現する。
        // ⚠️ 既知リスク: AVAudioSession .playback セッション中（再生中の Podcast）に
        //     AudioServicesPlaySystemSound を呼び出すと音が鳴らない/途切れることがある。
        //     実機テストでのみ確定でき、Simulator では検知できない既知の iOS 制限。
        //     TestFlight での実機検証時に再生中のクイズ採点音の再生を必ず確認すること。
        if sfxEnabled && (vocabulary == .correct || vocabulary == .streakUp) {
            AudioServicesPlaySystemSound(soundId(for: vocabulary))
        }
    }

    private func impactStyle(for vocabulary: DSFeedbackVocabulary) -> UIImpactFeedbackGenerator.FeedbackStyle? {
        switch vocabulary {
        case .correct, .streakUp, .swipeConfirm:
            return .light
        case .incorrect:
            return .soft
        case .achievement:
            return .medium
        }
    }

    private func soundId(for vocabulary: DSFeedbackVocabulary) -> SystemSoundID {
        // iOS システム音の制約により、音は correct (1103) と streakUp (1104) の 2 語彙のみに限定。
        // 他の語彙（incorrect, swipeConfirm, achievement）は触覚フィードバック（UIImpactFeedbackGenerator）
        // で性格を表現し、ユーザーの集中力を損なわない（ADR-088）。
        switch vocabulary {
        case .correct:
            // 1103 = Tink。短く明るい音で正答を肯定する。
            return 1103
        case .streakUp:
            // 1104 = Keyboard Press。継続達成の喜びを音で祝福する。
            return 1104
        case .incorrect:
            // 音なし。触覚（soft）で誤答の確認のみ。スコア圧迫を避ける。
            // 注: play() で vocabulary != .achievement チェックがあるが、
            // 誤答の場合も同様に音を避けるべき場合は play() ロジックを拡張する。
            return 0
        case .swipeConfirm:
            // 音なし。触覚（light）でペン先でチェックするような確定感のみ。
            return 0
        case .achievement:
            // 音なし。触覚（medium）で祝福（ADR-088 ファンファーレ禁止）。
            return 0
        }
    }
}
