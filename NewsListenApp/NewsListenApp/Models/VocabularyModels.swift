import Foundation

struct VocabularyItem: Codable, Equatable, Identifiable {
    let vocabularyId: String
    let podcastId: String
    let term: String
    let meaning: String
    let example: String
    let registeredAt: String

    var id: String { vocabularyId }

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case podcastId = "podcast_id"
        case term, meaning, example
        case registeredAt = "registered_at"
    }
}

struct VocabularyListResponse: Codable, Equatable {
    let vocabulary: [VocabularyItem]
    let count: Int
}

struct DeleteVocabularyResponse: Codable, Equatable {
    let status: String
    let vocabularyId: String

    enum CodingKeys: String, CodingKey {
        case status
        case vocabularyId = "vocabulary_id"
    }
}

struct VocabularyTestItem: Codable, Equatable, Identifiable {
    let vocabularyId: String
    let term: String
    let meaning: String
    let example: String
    let distractors: [String]

    var id: String { vocabularyId }

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case term, meaning, example, distractors
    }
}

struct VocabularyTestSessionResponse: Codable, Equatable {
    let items: [VocabularyTestItem]
}

struct VocabularyTestResultItem: Codable, Equatable {
    let vocabularyId: String
    let selfKnown: Bool
    let retestCorrect: Bool?

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case selfKnown = "self_known"
        case retestCorrect = "retest_correct"
    }
}

struct VocabularyTestResultResponse: Codable, Equatable {
    let updated: Int
}
