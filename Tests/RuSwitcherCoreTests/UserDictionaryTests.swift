import XCTest
@testable import RuSwitcherCore

final class UserDictionaryTests: XCTestCase {
    func testPastedTextSplitsOnLinesCommasAndWhitespaceAndDropsDuplicates() {
        var dictionary = UserDictionary()
        let report = dictionary.add(text: "Figma, Kubernetes\nкринж;  вайб\tTesla\r\n\nfigma \"Яндекс\" КРИНЖ pstack. GitHub NASA")
        XCTAssertEqual(dictionary.words, ["Figma", "Kubernetes", "кринж", "вайб", "Tesla", "Яндекс", "pstack", "GitHub", "NASA"])
        XCTAssertEqual(report, UserDictionary.Report(added: 9, duplicates: 2, invalid: 0, overLimit: 0))
        XCTAssertEqual(dictionary.wordsByLanguage["en"], ["figma", "kubernetes", "tesla", "pstack", "github", "nasa"])
        XCTAssertEqual(dictionary.wordsByLanguage["ru"], ["кринж", "вайб", "яндекс"])
        XCTAssertEqual(dictionary.add(text: "FIGMA вайб").duplicates, 2)
    }

    func testRejectsNumbersLinksMixedScriptsAndOverlongWords() {
        var dictionary = UserDictionary()
        let rejected = [
            "12345", "https://figma.com", "www.figma.com", "user@mail.ru", "приvet", "src/main",
            "gpt4", "x", "ё", "naïve", "C++", String(repeating: "a", count: 65),
        ]
        let report = dictionary.add(rejected + ["Сан-Франциско", "don't", String(repeating: "б", count: 64)])
        XCTAssertEqual(report, UserDictionary.Report(added: 3, duplicates: 0, invalid: 12, overLimit: 0))
        XCTAssertEqual(dictionary.words, ["Сан-Франциско", "don't", String(repeating: "б", count: 64)])
    }

    func testWordCountStopsAtTheLimit() {
        var dictionary = UserDictionary()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let words = (0..<(UserDictionary.maximumWordCount + 2)).map { index -> String in
            var value = index
            var word = ""
            for _ in 0..<4 {
                word.append(letters[value % 26])
                value /= 26
            }
            return "w" + word
        }
        let report = dictionary.add(words)
        XCTAssertEqual(report, UserDictionary.Report(added: 20_000, duplicates: 0, invalid: 0, overLimit: 2))
        XCTAssertEqual(dictionary.words.count, 20_000)
        dictionary.remove(["WAAAA"])
        XCTAssertEqual(dictionary.words.count, 19_999)
        XCTAssertEqual(dictionary.add(["waaaa"]).added, 1)
    }

    func testRemoveIgnoresCaseAndExportReadsBack() {
        var dictionary = UserDictionary(words: ["Figma", "кринж", "bad@mail.ru", "Tesla"])
        XCTAssertEqual(dictionary.words, ["Figma", "кринж", "Tesla"])
        dictionary.remove(["КРИНЖ"])
        XCTAssertEqual(dictionary.exportedText, "Figma\nTesla\n")
        var restored = UserDictionary()
        XCTAssertEqual(restored.add(text: dictionary.exportedText).added, 2)
        XCTAssertEqual(restored, dictionary)
        XCTAssertEqual(UserDictionary().exportedText, "")
    }
}
