//
//  PlaybackCoordinator.swift
//  NewsListenApp
//
//  再生の use case の判断（開始・次へ・失敗の手順と世代、キュー、ロック画面とリモートコマンド、
//  表示形態、割り込みの記憶、背景 task、知らせ）。engine の駆動と遷移の決定は `PlaybackSession`。
//

import Foundation
import Combine

enum PlaybackNotice: Equatable {
    case failure(PlaybackErrorReason)
    case loadWarning(String)
}

/// `deinit`（nonisolated）から解除できるように、token を MainActor の外に置く箱。
private final class RegistrationBox: @unchecked Sendable {
    fileprivate var token: RemoteCommandRegistration?
}

@MainActor
final class PlaybackCoordinator: ObservableObject, PlaybackLifecycle {
    @Published private(set) var session: PlaybackState = .idle
    @Published private(set) var presentation: PlayerPresentation = .hidden
    @Published private(set) var queue: PlaybackQueue<Episode> = PlaybackQueue()
    @Published private(set) var notice: PlaybackNotice?
    @Published private(set) var isAdvancing: Bool = false

    private typealias Prepared = (playable: PlayableEpisode, url: URL, serverPosition: Double)

    private enum StartCheck {
        case rejected(PlaybackErrorReason)
        case ready(playable: PlayableEpisode, url: URL, source: PlaybackSource)
    }

    private let playbackSession: PlaybackSession
    private let nowPlayingCenter: NowPlayingCenter
    private let library: OfflineLibrary
    private let reporter: PositionReporter
    private let fetchEpisode: (String) async throws -> Episode
    private let isOnline: () -> Bool
    private let defaultSpeed: () -> Float
    private let lockScreenSubtitle: (String) -> String
    private let beginBackgroundTask: () -> (() -> Void)
    private let registrationBox = RegistrationBox()
    private var generation = 0
    private var pendingUserStarts = 0
    private var interruptedWasPlaying: Bool?

    init(engine: any AudioEngine,
         nowPlayingCenter: NowPlayingCenter,
         library: OfflineLibrary,
         reporter: PositionReporter,
         fetchEpisode: @escaping (String) async throws -> Episode,
         isOnline: @escaping () -> Bool,
         defaultSpeed: @escaping () -> Float,
         lockScreenSubtitle: @escaping (_ difficulty: String) -> String,
         beginBackgroundTask: @escaping () -> (() -> Void)) {
        self.nowPlayingCenter = nowPlayingCenter
        self.library = library
        self.reporter = reporter
        self.fetchEpisode = fetchEpisode
        self.isOnline = isOnline
        self.defaultSpeed = defaultSpeed
        self.lockScreenSubtitle = lockScreenSubtitle
        self.beginBackgroundTask = beginBackgroundTask
        let playbackSession = PlaybackSession(engine: engine)
        self.playbackSession = playbackSession
        reporter.attach(playbackSession)
        playbackSession.observe { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        registrationBox.token?.cancel()
    }

    // MARK: - 手動の開始

    func startEpisode(_ episode: Episode, expandsPlayer: Bool = true) async {
        await startManually(episode, expandsPlayer: expandsPlayer, resolved: nil, enqueues: true, resumeOverride: nil)
    }

    func startEpisode(id: String) async throws {
        generation += 1
        let startedGeneration = generation
        pendingUserStarts += 1
        let resolved: Episode
        do {
            resolved = try await fetchEpisode(id)
        } catch {
            pendingUserStarts -= 1
            throw error
        }
        pendingUserStarts -= 1
        guard startedGeneration == generation else { return }
        await startManually(resolved, expandsPlayer: true, resolved: resolved, enqueues: true, resumeOverride: nil)
    }

    func replayCurrent() async {
        guard nowPlaying() != nil, let current = queue.current else { return }
        await startManually(current, expandsPlayer: false, resolved: nil, enqueues: false, resumeOverride: 0)
    }

    func retry() async {
        guard case .errored = session, let current = queue.current else { return }
        if case .rejected(let reason) = check(current) {
            failSession(episodeId: current.id, reason: reason)
            notice = .failure(reason)
            return
        }
        await startManually(current, expandsPlayer: false, resolved: nil, enqueues: false, resumeOverride: nil)
    }

    func togglePlayPause() {
        switch session {
        case .loading, .playing, .buffering:
            playbackSession.pause()
        case .paused:
            playbackSession.play()
        case .errored:
            Task { [weak self] in await self?.retry() }
        case .idle, .ended:
            break
        }
    }

    func seek(to seconds: Double) {
        playbackSession.seek(to: seconds)
    }

    func setSpeed(_ speed: Float) {
        playbackSession.setSpeed(speed)
    }

    func skipToNext() async {
        guard let next = queue.upNext.first else { return }
        let (playable, url, source): (PlayableEpisode, URL, PlaybackSource)
        switch check(next) {
        case .rejected(let reason):
            notice = .failure(reason)
            return
        case .ready(let readyPlayable, let readyURL, let readySource):
            (playable, url, source) = (readyPlayable, readyURL, readySource)
        }
        generation += 1
        let startedGeneration = generation
        pendingUserStarts += 1
        defer { pendingUserStarts -= 1 }
        guard let prepared = await prepare(playable, url, source, resolved: nil),
              startedGeneration == generation,
              queue.upNext.first?.id == next.id else { return }
        _ = queue.advance()
        confirmStart(prepared, expandsPlayer: false, resumeOverride: nil)
    }

    // MARK: - キュー

    func addToQueue(_ episode: Episode) async {
        let wasIdle = session == .idle
        queue.add(episode)
        if wasIdle { await startEpisode(episode) }
    }

    func playNext(_ episode: Episode) async {
        let wasIdle = session == .idle
        queue.playNext(episode)
        if wasIdle { await startEpisode(episode) }
    }

    func removeFromQueue(id: String) {
        guard id == queue.current?.id, session != .idle else {
            queue.remove(id: id)
            return
        }
        reporter.flush()
        queue.remove(id: id)
        stopSession()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.reorderUpNext(fromOffsets: source, toOffset: destination)
    }

    // MARK: - 読み取り

    func nowPlaying() -> NowPlaying? {
        guard session != .idle, let current = queue.current else { return nil }
        let content = current.content
        return NowPlaying(
            episodeId: content.id,
            displayTitle: content.displayTitle,
            japaneseIntroText: content.japaneseIntroText,
            segments: content.segments,
            vocabulary: content.vocabulary,
            quiz: content.quiz,
            difficulty: content.difficulty,
            sourceArticles: content.sourceArticles,
            sourceKind: content.sourceKind,
            hasTranscript: content.hasTranscript,
            hasVocabulary: content.hasVocabulary,
            hasQuiz: content.hasQuiz,
            hasSourceArticles: content.hasSourceArticles,
            showsCcBySaLicense: content.showsCcBySaLicense,
            queueEntry: queueEntry(for: content))
    }

    func upNext() -> [QueueEntry] {
        queue.upNext.map { queueEntry(for: $0.content) }
    }

    // MARK: - 知らせ・表示形態・主体離脱

    func dismissError() {
        notice = nil
    }

    func minimizePlayer() {
        if presentation != .hidden { presentation = .mini }
    }

    func expandPlayer() {
        if nowPlaying() != nil { presentation = .expanded }
    }

    func stopForLogout() {
        stopSession()
        nowPlayingCenter.clear()
        if let token = registrationBox.token {
            nowPlayingCenter.unregister(token)
            registrationBox.token = nil
        }
        queue = PlaybackQueue()
        presentation = .hidden
        notice = nil
        isAdvancing = false
        interruptedWasPlaying = nil
    }

    // MARK: - 自動で次へ

    func onEnded(endedId: String) async {
        guard endedId == queue.current?.id else { return }
        reporter.listenCompleted(id: endedId)
        if pendingUserStarts > 0 { return }
        while let next = queue.upNext.first {
            let playable: PlayableEpisode
            let url: URL
            let source: PlaybackSource
            switch check(next) {
            case .rejected(let reason):
                _ = queue.advance()
                failSession(episodeId: next.id, reason: reason)
                return
            case .ready(let readyPlayable, let readyURL, let readySource):
                (playable, url, source) = (readyPlayable, readyURL, readySource)
            }
            generation += 1
            let startedGeneration = generation
            isAdvancing = true
            let endBackgroundTask = beginBackgroundTask()
            let prepared = await prepare(playable, url, source, resolved: nil)
            endBackgroundTask()
            isAdvancing = false
            guard startedGeneration == generation, let prepared else { return }
            if queue.upNext.first?.id != next.id { continue }
            _ = queue.advance()
            confirmStart(prepared, expandsPlayer: false, resumeOverride: nil)
            return
        }
        nowPlayingCenter.clear()
    }

    #if DEBUG
    /// Preview 専用。写しの値を直接置く（Session は動かさない）。
    func previewSet(session: PlaybackState, queue: PlaybackQueue<Episode>) {
        self.session = session
        self.queue = queue
    }
    #endif

    // MARK: - 開始の流れ

    private func check(_ episode: Episode) -> StartCheck {
        guard case .playable(let playable) = episode, let url = URL(string: playable.audioUrl) else {
            return .rejected(.invalidSource)
        }
        let source = PlaybackRules.resolvePlaybackSource(hasCached: library.has(playable.content.id), isOnline: isOnline())
        if source == .unavailable { return .rejected(.offlineUncached) }
        return .ready(playable: playable, url: url, source: source)
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// 再生元の用意。`nil` は cancel による error（開始を捨てる）。
    private func prepare(_ held: PlayableEpisode, _ heldURL: URL, _ source: PlaybackSource, resolved: Episode?) async -> Prepared? {
        switch source {
        case .cached:
            return (held, library.url(held.content.id) ?? heldURL, held.serverPosition)
        case .network:
            do {
                let fetched: Episode
                if let resolved {
                    fetched = resolved
                } else {
                    fetched = try await fetchEpisode(held.content.id)
                }
                if case .playable(let playable) = fetched, let url = URL(string: playable.audioUrl) {
                    return (playable, url, playable.serverPosition)
                }
            } catch {
                if isCancellation(error) { return nil }
            }
            return (held, heldURL, held.serverPosition)
        case .unavailable:
            return nil
        }
    }

    private func startManually(_ episode: Episode,
                               expandsPlayer: Bool,
                               resolved: Episode?,
                               enqueues: Bool,
                               resumeOverride: Double?) async {
        let playable: PlayableEpisode
        let url: URL
        let source: PlaybackSource
        switch check(episode) {
        case .rejected(let reason):
            notice = .failure(reason)
            return
        case .ready(let readyPlayable, let readyURL, let readySource):
            (playable, url, source) = (readyPlayable, readyURL, readySource)
        }
        generation += 1
        let startedGeneration = generation
        pendingUserStarts += 1
        defer { pendingUserStarts -= 1 }
        guard let prepared = await prepare(playable, url, source, resolved: resolved),
              startedGeneration == generation else { return }
        if enqueues, !queue.jump(to: playable.content.id) {
            queue.playNext(episode)
            _ = queue.jump(to: playable.content.id)
        }
        confirmStart(prepared, expandsPlayer: expandsPlayer, resumeOverride: resumeOverride)
    }

    private func confirmStart(_ prepared: Prepared, expandsPlayer: Bool, resumeOverride: Double?) {
        generation += 1
        notice = nil
        isAdvancing = false
        interruptedWasPlaying = nil
        reporter.flush()
        let resumePosition = resumeOverride ?? PlaybackRules.resolveResumePosition(
            serverSeconds: prepared.serverPosition,
            durationSeconds: Double(prepared.playable.content.durationSeconds))
        let warning = playbackSession.start(
            episode: prepared.playable, url: prepared.url, resumePosition: resumePosition, speed: defaultSpeed())
        if let warning { notice = .loadWarning(warning) }
        if expandsPlayer {
            presentation = .expanded
        } else if presentation == .hidden {
            presentation = .mini
        }
        registerRemoteCommandsIfNeeded()
    }

    private func stopSession() {
        generation += 1
        playbackSession.stop()
    }

    private func failSession(episodeId: String, reason: PlaybackErrorReason) {
        generation += 1
        playbackSession.fail(episodeId: episodeId, reason: reason)
    }

    private func queueEntry(for content: EpisodeContent) -> QueueEntry {
        QueueEntry(episodeId: content.id,
                   introText: content.japaneseIntroText,
                   difficulty: content.difficulty,
                   durationSeconds: content.durationSeconds)
    }

    // MARK: - Session の通知

    private func handle(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let state):
            session = state
            updateLockScreen(for: state)
            if case .errored(_, _, let reason) = state { notice = .failure(reason) }
        case .positionChanged(let seconds, let duration):
            session = playbackSession.state
            nowPlayingCenter.updateElapsed(seconds, duration: duration)
        case .ended(let episodeId):
            Task { [weak self] in await self?.onEnded(endedId: episodeId) }
        case .interruption(let phase):
            handleInterruption(phase)
        }
    }

    private func handleInterruption(_ phase: InterruptionPhase) {
        switch phase {
        case .began(let wasPlaying):
            interruptedWasPlaying = wasPlaying
        case .ended(let shouldResume):
            if shouldResume, interruptedWasPlaying == true, case .paused = session {
                playbackSession.play()
            }
            interruptedWasPlaying = nil
        }
    }

    private func updateLockScreen(for state: PlaybackState) {
        switch state {
        case .loading, .playing, .buffering, .paused:
            guard let current = queue.current else {
                nowPlayingCenter.clear()
                return
            }
            let isPlaying: Bool
            if case .paused = state { isPlaying = false } else { isPlaying = true }
            nowPlayingCenter.update(NowPlayingSnapshot(
                title: current.content.displayTitle,
                subtitle: lockScreenSubtitle(current.content.difficulty),
                elapsed: state.position,
                duration: state.duration,
                rate: state.speed ?? 1.0,
                isPlaying: isPlaying))
        case .idle, .errored:
            nowPlayingCenter.clear()
        case .ended:
            break
        }
    }

    // MARK: - リモートコマンド

    private func registerRemoteCommandsIfNeeded() {
        guard registrationBox.token == nil else { return }
        registrationBox.token = nowPlayingCenter.registerCommands { [weak self] command in
            self?.handleRemote(command) ?? .commandFailed
        }
    }

    private func handleRemote(_ command: RemoteCommand) -> RemoteCommandResult {
        let operable = PlaybackRules.isLoaded(session)
        switch command {
        case .play:
            guard operable else { return .noSuchContent }
            if case .paused = session { playbackSession.play() }
            return .success
        case .pause:
            guard operable else { return .noSuchContent }
            if case .paused = session { return .success }
            playbackSession.pause()
            return .success
        case .togglePlayPause:
            guard operable else { return .noSuchContent }
            togglePlayPause()
            return .success
        case .skipBackward:
            guard operable else { return .noSuchContent }
            playbackSession.seekRelative(-PlaybackConstants.skipBackwardSeconds)
            return .success
        case .skipForward:
            guard operable else { return .noSuchContent }
            playbackSession.seekRelative(PlaybackConstants.skipForwardSeconds)
            return .success
        case .changePosition(let seconds):
            guard operable else { return .commandFailed }
            seek(to: seconds)
            return .success
        case .changeRate(let rate):
            guard operable else { return .noSuchContent }
            setSpeed(rate)
            return .success
        }
    }
}
