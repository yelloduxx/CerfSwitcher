import XCTest
@testable import RuSwitcherCore

final class LanguageModelStoreTests: XCTestCase {
    func testBundledModelLoadsAndHasPinnedMetadata() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertEqual(model.metadata.formatVersion, 2)
        XCTAssertEqual(model.metadata.modelVersion, "2026.08-v3.1-ranked-en3")
        XCTAssertEqual(model.metadata.sourceRevision, "e20471c15a758be3362b16d07870b34df4f7ccc3")
        XCTAssertGreaterThan(model.metadata.wordCounts["ru"] ?? 0, 9_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["en"] ?? 0, 9_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["enExtended"] ?? 0, 80_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["enExtendedCommon"] ?? 0, 30_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["enExtendedStandard"] ?? 0, 20_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["enExtendedRare"] ?? 0, 10_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["ruExtended"] ?? 0, 1_000_000)
        XCTAssertGreaterThan(model.trainingExtendedEnglishWords().count, 80_000)
        XCTAssertEqual(model.englishSpellingTier("Fahrenheit"), .common)
        XCTAssertEqual(model.englishSpellingTier("middleware"), .rare)
        XCTAssertNil(model.englishSpellingTier("the"), "frequent words live in the ranked word section")
        XCTAssertEqual(model.thresholds.englishTargetStrongCharacterBonus, 3.0)
        XCTAssertEqual(model.thresholds.englishTargetStrongCharacterContextRecovery, 1.0)
        for word in ["ввод", "сервер", "отчёт", "буфер", "клавиатура", "платёж"] {
            XCTAssertTrue(model.isExtendedRussianWord(word), word)
        }
    }

    func testCompoundIsDiscoveredFromPartsRatherThanWholeWord() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertFalse(model.contains("суперспина", language: "ru"))
        let analysis = try XCTUnwrap(CompoundWordAnalyzer.analyze("суперспина", language: "ru", model: model))
        XCTAssertEqual(analysis.segments, ["супер", "спина"])
    }

    func testProductiveColloquialSuffixUsesKnownStem() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertFalse(model.contains("приветульки", language: "ru"))
        let analysis = try XCTUnwrap(CompoundWordAnalyzer.analyze("приветульки", language: "ru", model: model))
        XCTAssertEqual(analysis.segments, ["привет", "ульки"])
    }

    func testChecksumRejectsCorruptedModel() throws {
        let url = try XCTUnwrap(LanguageModelStore.bundledResourceURL)
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0xff
        XCTAssertThrowsError(try LanguageModelStore(data: data)) { error in
            XCTAssertEqual(error as? LanguageModelError, .checksumMismatch)
        }
    }
}
