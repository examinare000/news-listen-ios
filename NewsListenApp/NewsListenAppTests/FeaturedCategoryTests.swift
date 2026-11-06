import XCTest
@testable import NewsListenApp

/// おすすめサイトのカテゴリ分類と正規化ロジック（domain）のテスト。要素の型を問わない並べ方なので通信のデータモデルは使わない。
/// Backend API の category フィールド（tech, business, sports, entertainment, culture）に対応。
final class FeaturedCategoryTests: XCTestCase {

    // verifies: ios-rule-sources-01
    func testAllCategoriesListFiveCategoriesInDisplayOrder() {
        XCTAssertEqual(
            FeaturedCategory.allCases.map(\.rawValue),
            ["tech", "business", "sports", "entertainment", "culture"]
        )
    }

    // verifies: ios-rule-sources-01
    func testJapaneseLabelForEachCategory() {
        XCTAssertEqual(FeaturedCategory.tech.label, "テクノロジー")
        XCTAssertEqual(FeaturedCategory.business.label, "ビジネス")
        XCTAssertEqual(FeaturedCategory.sports.label, "スポーツ")
        XCTAssertEqual(FeaturedCategory.entertainment.label, "芸能")
        XCTAssertEqual(FeaturedCategory.culture.label, "カルチャー")
    }

    // verifies: ios-rule-sources-01
    func testNormalizeReturnsKnownCategoryAsIs() {
        XCTAssertEqual(FeaturedCategory.normalize("tech"), .tech)
        XCTAssertEqual(FeaturedCategory.normalize("business"), .business)
        XCTAssertEqual(FeaturedCategory.normalize("sports"), .sports)
        XCTAssertEqual(FeaturedCategory.normalize("entertainment"), .entertainment)
        XCTAssertEqual(FeaturedCategory.normalize("culture"), .culture)
    }

    // verifies: ios-rule-sources-01
    func testNormalizeReturnsNilAsDefaultTech() {
        XCTAssertEqual(FeaturedCategory.normalize(nil), .tech)
    }

    // verifies: ios-rule-sources-01
    func testNormalizeReturnsUnknownValueAsDefaultTech() {
        XCTAssertEqual(FeaturedCategory.normalize("unknown"), .tech)
        XCTAssertEqual(FeaturedCategory.normalize(""), .tech)
        XCTAssertEqual(FeaturedCategory.normalize("TECH"), .tech)
    }

    // verifies: ios-test-050
    func testGroupByCategoryInOrderGroupsAndFiltersEmptyCategories() {
        let sites: [(id: String, category: String?)] = [
            (id: "1", category: "tech"),
            (id: "2", category: "tech"),
            (id: "3", category: "business"),
            (id: "4", category: "sports"),
        ]

        let grouped = FeaturedCategory.grouped(sites, category: { FeaturedCategory.normalize($0.category) })

        XCTAssertEqual(grouped.first { $0.category == .tech }?.items.count, 2)
        XCTAssertEqual(grouped.first { $0.category == .tech }?.items[0].id, "1")
        XCTAssertEqual(grouped.first { $0.category == .tech }?.items[1].id, "2")

        XCTAssertEqual(grouped.first { $0.category == .business }?.items.count, 1)
        XCTAssertEqual(grouped.first { $0.category == .business }?.items[0].id, "3")

        XCTAssertEqual(grouped.first { $0.category == .sports }?.items.count, 1)
        XCTAssertEqual(grouped.first { $0.category == .sports }?.items[0].id, "4")

        XCTAssertNil(grouped.first { $0.category == .entertainment }, "空のカテゴリは出さない")
        XCTAssertNil(grouped.first { $0.category == .culture }, "空のカテゴリは出さない")
    }

    // verifies: ios-test-050
    func testGroupByCategoryInOrderNormalizesMissingCategory() {
        let sites: [(id: String, category: String?)] = [
            (id: "1", category: nil),
            (id: "2", category: "unknown"),
        ]

        let grouped = FeaturedCategory.grouped(sites, category: { FeaturedCategory.normalize($0.category) })

        XCTAssertEqual(grouped.first { $0.category == .tech }?.items.count, 2)
        XCTAssertEqual(grouped.first { $0.category == .tech }?.items[0].id, "1")
        XCTAssertEqual(grouped.first { $0.category == .tech }?.items[1].id, "2")
    }

    // verifies: ios-test-050
    func testGroupByCategoryInOrderPreservesServerOrder() {
        let sites: [(id: String, category: String?)] = [
            (id: "a", category: "tech"),
            (id: "b", category: "tech"),
            (id: "c", category: "tech"),
        ]

        let grouped = FeaturedCategory.grouped(sites, category: { FeaturedCategory.normalize($0.category) })

        XCTAssertEqual(grouped.first { $0.category == .tech }?.items.map(\.id), ["a", "b", "c"])
    }

    // verifies: ios-rule-sources-01
    func testGroupedReturnsGroupsInDisplayOrderNotInputOrder() {
        let items: [(id: String, category: String?)] = [
            (id: "c", category: "culture"),
            (id: "t", category: "tech"),
        ]

        let result = FeaturedCategory.grouped(items, category: { FeaturedCategory.normalize($0.category) })

        XCTAssertEqual(result.map(\.category), [.tech, .culture])
    }

    // verifies: ios-check-16
    func testInitAcceptsOnlyTheFiveExactRawValues() {
        for raw in ["tech", "business", "sports", "entertainment", "culture"] {
            XCTAssertEqual(FeaturedCategory(rawValue: raw)?.rawValue, raw)
        }
        for raw in ["TECH", "", "x"] {
            XCTAssertNil(FeaturedCategory(rawValue: raw), "\(raw) は値域外")
        }
    }
}
