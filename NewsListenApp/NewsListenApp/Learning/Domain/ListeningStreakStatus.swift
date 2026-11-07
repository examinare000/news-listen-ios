import Foundation

struct ListeningStreakStatus: Equatable {
    let days: Int
    let listenedToday: Bool
    let lastListenedDay: String?

    var isShown: Bool {
        lastListenedDay != nil && days > 0
    }

    static func didIncrease(from previous: ListeningStreakStatus?, to next: ListeningStreakStatus) -> Bool {
        guard let previous else { return false }
        return next.days > previous.days
    }
}
