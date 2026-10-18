import Foundation

/// 生成境界の検査（ios-check-16）の GREEN の対照になる合成の値型。
/// 格納プロパティは `let` だけ、生成の入口は検査つきだけ（素の生成子を持たない）。
/// 検査は、この本文を domain の層のファイルとして読む（`ArchitectureFixtureTests`）。
/// computed の `var` を 1 つ持つのは、computed が格納プロパティとして数えられないことの正の対照にするため。
struct ValidatedFixture {
    let name: String
    let count: Int

    var label: String { name + ":" + String(count) }

    private init(name: String, count: Int) {
        self.name = name
        self.count = count
    }

    static func make(name: String, count: Int) -> ValidatedFixture? {
        guard !name.isEmpty, count >= 0 else { return nil }
        return ValidatedFixture(name: name, count: count)
    }
}
