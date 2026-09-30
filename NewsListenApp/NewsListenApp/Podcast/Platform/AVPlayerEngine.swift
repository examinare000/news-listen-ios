//
//  AVPlayerEngine.swift
//  NewsListenApp
//
//  `AudioEngine` の本番実装。`AVPlayer` / `AVAudioSession` を隠す adapter。
//  AVFoundation の callback を `EngineEvent` の stream へ変換する（PodcastViewModel から移した部分）。
//

import AVFoundation

/// `AVPlayer` を使う `AudioEngine` の本番実装。
///
/// callback の配送規則は寿命で 2 種類に分ける。
/// - load 固有の callback（定期更新・item.status・timeControlStatus・再生終了）は、その load の最初の
///   `play()` で登録し、登録時の continuation を閉じ込める。さらに main へホップした後に identity ガードを通った
///   場合にだけ yield する（`stop` / 再 load 後の古い発火を捨てる。issue #59）。
/// - adapter 寿命の通知（割り込み・route change）は初回 load で 1 回だけ登録し、解除しない。発火時の
///   「現在の load の continuation」へ流す（load をやり直した後も新しい stream へ届く）。
@MainActor
final class AVPlayerEngine: AudioEngine {
    /// VM の既定引数（nonisolated な文脈）から生成できるよう、init は隔離しない。
    nonisolated init() {}

    /// 現在の `AVPlayer`（未読み込みなら `nil`）。テストが現在の item / player を参照するために internal read。
    private(set) var player: AVPlayer?

    /// 割り込み終了（shouldResume）の後、最初の再開の前に `setActive(true)` を呼ぶ必要があるか。
    /// 立てるのは `interruptionEnded(shouldResume: true)` の受信だけ。使うのはその後の最初の `play` / `setRate`。
    /// `stop` / `load` / 割り込み began の受信でも倒す。**`pause` では倒さない**（VM は `interrupted` を
    /// 1 ホップ遅れて消費して `pause` を呼ぶので、先に受信していた ended のフラグを消してしまう）。
    private(set) var needsSessionReactivation = false

    private var stream: AsyncStream<EngineEvent>?
    private var continuation: AsyncStream<EngineEvent>.Continuation?

    private var timeObserver: Any?
    private var endOfPlaybackObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var loadObserversRegistered = false
    private var systemNotificationsRegistered = false

    // MARK: - AudioEngine

    func load(url: URL) -> String? {
        stop()
        let warning = configureAudioSession()
        registerSystemNotificationsIfNeeded()

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        let (newStream, newContinuation) = AsyncStream.makeStream(of: EngineEvent.self)
        stream = newStream
        continuation = newContinuation
        return warning
    }

    func play() {
        guard let player else { return }
        registerLoadObserversIfNeeded()
        reactivateSessionIfNeeded()
        player.play()
    }

    func pause() {
        player?.pause()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func setRate(_ rate: Float) {
        guard let player else { return }
        reactivateSessionIfNeeded()
        player.rate = rate
    }

    func stop() {
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        if let endObserver = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(endObserver)
            endOfPlaybackObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlStatusObservation?.invalidate()
        timeControlStatusObservation = nil
        loadObserversRegistered = false
        player?.pause()
        player = nil
        continuation?.finish()
        continuation = nil
        stream = nil
        needsSessionReactivation = false
    }

    var events: AsyncStream<EngineEvent> {
        if let stream { return stream }
        return AsyncStream { $0.finish() }
    }

    // MARK: - stale ガード（issue #59）

    /// 通知された `AVPlayerItem` が現在の item と同一か。`stop` → 次の `load` の競合で item が差し替わった後の
    /// 古い callback を捨てるために使う。
    func isCurrentItem(_ item: AVPlayerItem) -> Bool {
        item === player?.currentItem
    }

    /// 通知された `AVPlayer` が現在の player と同一か。理由は ``isCurrentItem(_:)`` と同じ。
    func isCurrentPlayer(_ candidate: AVPlayer) -> Bool {
        candidate === player
    }

    // MARK: - AudioSession

    /// `.playback` / `.spokenAudio` に設定して有効化する。失敗しても読み込みは続け、説明を返す。
    /// マナーモード（消音スイッチ ON）でも再生されるようにするため。
    private func configureAudioSession() -> String? {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reactivateSessionIfNeeded() {
        guard needsSessionReactivation else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        needsSessionReactivation = false
    }

    // MARK: - load 固有の callback

    /// その load の最初の `play()` で、定期更新・item 状態・再生状態・再生終了の購読を登録する。
    private func registerLoadObserversIfNeeded() {
        guard !loadObserversRegistered, let player, let item = player.currentItem, let continuation else { return }
        loadObserversRegistered = true

        // 再生位置の定期更新（0.5 秒ごと）。queue: .main 指定により常にメインスレッドで呼ばれる。
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                // player を強参照すると AVPlayer → block → player の循環になり、stop 前の解放で player が残る。
                guard let self, let player, self.isCurrentPlayer(player) else { return }
                let itemDuration = item.duration.seconds
                continuation.yield(.timeUpdate(seconds: time.seconds, duration: itemDuration.isNaN ? 0 : itemDuration))
            }
        }

        // KVO のコールバックはメインスレッドで発火する保証が無いため、main へホップしてから隔離を明示する。
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentItem(observed) else { return }
                    switch observed.status {
                    case .failed:
                        continuation.yield(.failed(description: observed.error?.localizedDescription))
                    case .readyToPlay:
                        continuation.yield(.ready)
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
            }
        }
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentPlayer(observed) else { return }
                    switch observed.timeControlStatus {
                    case .waitingToPlayAtSpecifiedRate:
                        continuation.yield(.buffering)
                    case .playing:
                        continuation.yield(.resumed)
                    case .paused:
                        continuation.yield(.paused)
                    @unknown default:
                        break
                    }
                }
            }
        }

        // object に item を指定し、当該 load の再生終了だけを購読する。
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrentItem(item) else { return }
                continuation.yield(.ended)
            }
        }
    }

    // MARK: - adapter 寿命の通知（割り込み・route change）

    /// 初回 load で 1 回だけ登録し、解除しない。クロージャは adapter を弱参照で捕捉する。
    /// `AVAudioSession` の通知はメインスレッド配信が保証されないため `queue: .main` で受ける。
    private func registerSystemNotificationsIfNeeded() {
        guard !systemNotificationsRegistered else { return }
        systemNotificationsRegistered = true
        let center = NotificationCenter.default
        _ = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        _ = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            needsSessionReactivation = false
            continuation?.yield(.interrupted)
        case .ended:
            let options: AVAudioSession.InterruptionOptions
            if let raw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: raw)
            } else {
                options = []
            }
            let shouldResume = InterruptionPolicy.shouldResume(options: options)
            // フラグの更新は、流し先（読み込み済みの load）の有無に関係なく行う。
            if shouldResume { needsSessionReactivation = true }
            continuation?.yield(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if InterruptionPolicy.shouldPause(forRouteChangeReason: reason) {
            continuation?.yield(.outputDeviceLost)
        }
    }
}
