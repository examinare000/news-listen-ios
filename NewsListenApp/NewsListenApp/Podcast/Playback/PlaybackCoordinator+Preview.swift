//
//  PlaybackCoordinator+Preview.swift
//  NewsListenApp
//
//  Preview 専用の組み立て。engine・ロック画面・保存庫・送信は「何もしない」実装を渡す。
//

#if DEBUG
import Foundation
import Combine

extension PlaybackCoordinator {
    static func previewParts(
        session: PlaybackState,
        queue: PlaybackQueue<Episode>
    ) -> (coordinator: PlaybackCoordinator, reporter: PositionReporter, library: OfflineLibrary) {
        let library = OfflineLibrary(store: previewStore)
        let reporter = PositionReporter(
            updatePosition: { _, _ in throw CancellationError() },
            markCompleted: { _ in },
            onPositionSaved: { _ in },
            onCompletionRecorded: {},
            beginBackgroundTask: { {} })
        let coordinator = PlaybackCoordinator(
            engine: IdleAudioEngine(),
            nowPlayingCenter: IdleNowPlayingCenter(),
            library: library,
            reporter: reporter,
            fetchEpisode: { _ in throw CancellationError() },
            isOnline: { false },
            defaultSpeed: { 1.0 },
            lockScreenSubtitle: { $0 },
            beginBackgroundTask: { {} })
        coordinator.previewSet(session: session, queue: queue)
        return (coordinator, reporter, library)
    }

    private static let previewStore = AudioFileStore(
        url: { _ in nil },
        exists: { _ in false },
        write: { _, _ in },
        remove: { _ in },
        removeAll: {},
        size: { 0 })
}

@MainActor
private final class IdleAudioEngine: AudioEngine {
    fileprivate let events = AsyncStream<EngineEvent> { _ in }

    fileprivate func load(url: URL) -> String? { nil }
    fileprivate func play() {}
    fileprivate func pause() {}
    fileprivate func seek(to seconds: Double) {}
    fileprivate func setRate(_ rate: Float) {}
    fileprivate func stop() {}
}

private final class IdleNowPlayingCenter: NowPlayingCenter {
    fileprivate func update(_ snapshot: NowPlayingSnapshot) {}
    fileprivate func updateElapsed(_ elapsed: Double, duration: Double) {}
    fileprivate func clear() {}

    fileprivate func registerCommands(
        _ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult
    ) -> RemoteCommandRegistration {
        RemoteCommandRegistration(removal: {})
    }

    fileprivate func unregister(_ registration: RemoteCommandRegistration) {}
}
#endif
