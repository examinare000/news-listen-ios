import Foundation

struct WeeklyProgress: Equatable {
    let completed: Int
    let goal: Int

    var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(max(Double(completed) / Double(goal), 0), 1)
    }
}
