import XCTest
@testable import NewsListenApp

/// Featured sites のカテゴリ分類と正規化ロジックのテスト。
/// Backend API の category フィールド（tech, business, sports, entertainment, culture）に対応。
final class FeaturedCategoryTests: XCTestCase {

    func testAllCategoriesListFiveCategoriesInDisplayOrder() {
        XCTAssertEqual(
            FeaturedCategory.allCases.map(\.rawValue),
            ["tech", "business", "sports", "entertainment", "culture"]
        )
    }

    func testJapaneseLabelForEachCategory() {
        XCTAssertEqual(FeaturedCategory.tech.label, "テクノロジー")
        XCTAssertEqual(FeaturedCategory.business.label, "ビジネス")
        XCTAssertEqual(FeaturedCategory.sports.label, "スポーツ")
        XCTAssertEqual(FeaturedCategory.entertainment.label, "芸能")
        XCTAssertEqual(FeaturedCategory.culture.label, "カルチャー")
    }

    func testNormalizeReturnsKnownCategoryAsIs() {
        XCTAssertEqual(FeaturedCategory.normalize("tech"), .tech)
        XCTAssertEqual(FeaturedCategory.normalize("business"), .business)
        XCTAssertEqual(FeaturedCategory.normalize("sports"), .sports)
        XCTAssertEqual(FeaturedCategory.normalize("entertainment"), .entertainment)
        XCTAssertEqual(FeaturedCategory.normalize("culture"), .culture)
    }

    func testNormalizeReturnsNilAsDefaultTech() {
        XCTAssertEqual(FeaturedCategory.normalize(nil), .tech)
    }

    func testNormalizeReturnsUnknownValueAsDefaultTech() {
        XCTAssertEqual(FeaturedCategory.normalize("unknown"), .tech)
        XCTAssertEqual(FeaturedCategory.normalize(""), .tech)
        XCTAssertEqual(FeaturedCategory.normalize("TECH"), .tech)
    }

    func testGroupByCategoryInOrderGroupsAndFiltersEmptyCategories() {
        let sites: [FeaturedSite] = [
            FeaturedSite(id: "1", name: "Tech News", url: "http://tech.com", thumbnailURL: nil, description: nil, category: "tech"),
            FeaturedSite(id: "2", name: "Tech News 2", url: "http://tech2.com", thumbnailURL: nil, description: nil, category: "tech"),
            FeaturedSite(id: "3", name: "Business Times", url: "http://business.com", thumbnailURL: nil, description: nil, category: "business"),
            FeaturedSite(id: "4", name: "Sports Daily", url: "http://sports.com", thumbnailURL: nil, description: nil, category: "sports"),
        ]

        let grouped = FeaturedCategory.groupByCategoryInOrder(sites)

        XCTAssertEqual(grouped[.tech]?.count, 2)
        XCTAssertEqual(grouped[.tech]?[0].id, "1")
        XCTAssertEqual(grouped[.tech]?[1].id, "2")

        XCTAssertEqual(grouped[.business]?.count, 1)
        XCTAssertEqual(grouped[.business]?[0].id, "3")

        XCTAssertEqual(grouped[.sports]?.count, 1)
        XCTAssertEqual(grouped[.sports]?[0].id, "4")

        XCTAssertEqual(grouped[.entertainment]?.count, 0)
        XCTAssertEqual(grouped[.culture]?.count, 0)
    }

    func testGroupByCategoryInOrderNormalizesMissingCategory() {
        let sites: [FeaturedSite] = [
            FeaturedSite(id: "1", name: "No Category", url: "http://none.com", thumbnailURL: nil, description: nil, category: nil),
            FeaturedSite(id: "2", name: "Unknown Category", url: "http://unknown.com", thumbnailURL: nil, description: nil, category: "unknown"),
        ]

        let grouped = FeaturedCategory.groupByCategoryInOrder(sites)

        XCTAssertEqual(grouped[.tech]?.count, 2)
        XCTAssertEqual(grouped[.tech]?[0].id, "1")
        XCTAssertEqual(grouped[.tech]?[1].id, "2")
    }

    func testGroupByCategoryInOrderPreservesServerOrder() {
        let sites: [FeaturedSite] = [
            FeaturedSite(id: "a", name: "A", url: "http://a.com", thumbnailURL: nil, description: nil, category: "tech"),
            FeaturedSite(id: "b", name: "B", url: "http://b.com", thumbnailURL: nil, description: nil, category: "tech"),
            FeaturedSite(id: "c", name: "C", url: "http://c.com", thumbnailURL: nil, description: nil, category: "tech"),
        ]

        let grouped = FeaturedCategory.groupByCategoryInOrder(sites)

        XCTAssertEqual(grouped[.tech]?.map(\.id), ["a", "b", "c"])
    }
}
