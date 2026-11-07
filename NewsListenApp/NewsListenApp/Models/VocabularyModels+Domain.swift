import Foundation

extension VocabularyTestItem {
    func toWord() -> VocabularyTestWord {
        VocabularyTestWord(id: vocabularyId, term: term, meaning: meaning, example: example, distractors: distractors)
    }
}

extension VocabularyTest {
    var resultPayload: [VocabularyTestResultItem] {
        outcomes.map { outcome in
            VocabularyTestResultItem(vocabularyId: outcome.wordId, selfKnown: outcome.selfKnown, retestCorrect: outcome.retestCorrect)
        }
    }
}
