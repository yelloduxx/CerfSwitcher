import XCTest
@testable import RuSwitcherCore

final class SmartTokenizerTests: XCTestCase {
    func testTrailingSlashIsPunctuationButInnerSlashIsAPath() {
        let word = SmartTokenizer.shape(of: "ghbdtn/")
        XCTAssertEqual(word.lexicalCore, "ghbdtn")
        XCTAssertEqual(word.suffix, "/")
        XCTAssertEqual(word.kind, .lexical)
        for path in ["src/main", "/usr", "a/b/", "~/Documents"] {
            XCTAssertEqual(SmartTokenizer.shape(of: path).kind, .identifier, path)
        }
    }

    func testSeparatesUnicodeQuotesAndPunctuation() {
        let shape = SmartTokenizer.shape(of: "«привет,»")
        XCTAssertEqual(shape.prefix, "«")
        XCTAssertEqual(shape.lexicalCore, "привет")
        XCTAssertEqual(shape.suffix, ",»")
        XCTAssertEqual(shape.kind, .lexical)
    }

    func testLexicalCoreKeepsLettersAndInnerPunctuation() {
        let cases: [(raw: String, prefix: String, core: String, suffix: String)] = [
            ("b", "", "b", ""),
            ("htdjk.wbz", "", "htdjk.wbz", ""),
            ("ghbdtn,", "", "ghbdtn", ","),
            ("(ghbdtn)", "(", "ghbdtn", ")"),
        ]
        for (raw, prefix, core, suffix) in cases {
            let shape = SmartTokenizer.shape(of: raw)
            XCTAssertEqual(shape.prefix, prefix, raw)
            XCTAssertEqual(shape.lexicalCore, core, raw)
            XCTAssertEqual(shape.suffix, suffix, raw)
        }
        XCTAssertEqual(SmartTokenizer.kind(of: "b"), .lexical)
        XCTAssertEqual(SmartTokenizer.kind(of: "ghbdtn"), .lexical)
        XCTAssertEqual(SmartTokenizer.kind(of: "abc1"), .identifier)
    }

    func testRecognizesProtectedStructuredTokens() {
        XCTAssertEqual(SmartTokenizer.kind(of: "https://example.com/a"), .url)
        XCTAssertEqual(SmartTokenizer.kind(of: "me@example.com"), .email)
        XCTAssertEqual(SmartTokenizer.kind(of: "snake_case"), .identifier)
        XCTAssertEqual(SmartTokenizer.kind(of: "myURL"), .identifier)
        XCTAssertEqual(SmartTokenizer.kind(of: "abcЖ"), .mixedScript)
    }

    func testTrailingDecorationsDoNotTurnWordsIntoIdentifiers() {
        for token in ["input_", "input-", "input—"] {
            let shape = SmartTokenizer.shape(of: token)
            XCTAssertEqual(shape.lexicalCore, "input", token)
            XCTAssertEqual(shape.kind, .lexical, token)
        }
        XCTAssertEqual(SmartTokenizer.kind(of: "snake_case"), .identifier)
    }

    func testPlainUppercaseAcronymIsDistinctFromStructuredIdentifier() {
        for token in ["SEO", "ЫУЩ", "«SEO,»"] {
            XCTAssertTrue(SmartTokenizer.isAllUppercaseWord(token), token)
        }
        for token in ["A", "NASA_", "HTTPServer", "SEO.com", "snake_case"] {
            XCTAssertFalse(SmartTokenizer.isAllUppercaseWord(token), token)
        }
    }
}
