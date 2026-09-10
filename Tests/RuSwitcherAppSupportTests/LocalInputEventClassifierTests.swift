import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

final class LocalInputEventClassifierTests: XCTestCase {
    func testPhysicalSpaceCompositionPrecedesEditingModifiers() {
        for text in ["'", "\"", "\u{00B4}", "\" ", "\t", "\n"] {
            let key = makeKey(49, text: text)
            for modifiers in editingModifiers {
                XCTAssertEqual(
                    classify(key, modifiers: modifiers), .compositionCommit,
                    "text=\(text.debugDescription), modifiers=\(modifiers)"
                )
            }
        }
    }

    func testPhysicalSpaceBoundaryPrecedesEditingModifiers() {
        let payloads: [String?] = [nil, "", " "]
        for text in payloads {
            let key = makeKey(49, text: text)
            for modifiers in editingModifiers {
                XCTAssertEqual(classify(key, modifiers: modifiers), .boundary(.space(count: 1)))
            }
        }
    }

    func testSpaceClassificationUsesFullPayloadNotOnlyFirstCharacter() {
        let key = TypedKey(
            keyCode: 49, shift: false, caps: false,
            producedCharacter: " ", producedText: " '", sourceLayoutID: "test.local"
        )
        XCTAssertEqual(classify(key), .compositionCommit)
    }

    func testEnterAndTabRemainBoundariesRegardlessOfPayloadOrModifiers() {
        let cases: [(UInt16, InputBoundary)] = [(36, .enter), (48, .tab)]
        let payloads: [String?] = [nil, "", " ", "'", "\r", "\n", "\t"]
        for (code, boundary) in cases {
            for text in payloads {
                for modifiers in editingModifiers {
                    XCTAssertEqual(classify(makeKey(code, text: text), modifiers: modifiers), .boundary(boundary))
                }
            }
        }
    }

    func testNavigationKeysInvalidateRegardlessOfModifiersOrPrintablePayload() {
        let codes: [UInt16] = [123, 124, 125, 126, 115, 119, 116, 121]
        for code in codes {
            for modifiers in editingModifiers {
                XCTAssertEqual(
                    classify(makeKey(code, text: "a", shift: true, caps: true), modifiers: modifiers),
                    .editing(.navigation), "keyCode=\(code), modifiers=\(modifiers)"
                )
            }
        }
    }

    func testPlainBackspaceIgnoresShiftAndCapsLock() {
        for shift in [false, true] {
            for caps in [false, true] {
                XCTAssertEqual(
                    classify(makeKey(51, text: "\u{8}", shift: shift, caps: caps)),
                    .editing(.plainBackspace)
                )
            }
        }
    }

    func testModifiedBackspacePrecedesGenericModifierNavigation() {
        for modifiers in editingModifiers where modifiers.command || modifiers.control || modifiers.option {
            XCTAssertEqual(
                classify(makeKey(51, text: "\u{7F}"), modifiers: modifiers),
                .editing(.modifiedDeletion), "modifiers=\(modifiers)"
            )
        }
    }

    func testForwardDeleteIsAlwaysModifiedDeletion() {
        for modifiers in editingModifiers {
            XCTAssertEqual(
                classify(makeKey(117, shift: true, caps: true), modifiers: modifiers),
                .editing(.modifiedDeletion)
            )
        }
    }

    func testCommandZIsUndoWithAdditionalModifiersAndEitherCase() {
        for modifiers in editingModifiers where modifiers.command {
            for shift in [false, true] {
                for caps in [false, true] {
                    XCTAssertEqual(
                        classify(makeKey(6, text: "\u{044F}", shift: shift, caps: caps), modifiers: modifiers),
                        .editing(.undo)
                    )
                }
            }
        }
    }

    func testCommandACVXAreClipboardCommandsByPhysicalKey() {
        let codes: [UInt16] = [0, 8, 9, 7]
        for code in codes {
            for modifiers in editingModifiers where modifiers.command {
                XCTAssertEqual(
                    classify(makeKey(code, text: "z", shift: true, caps: true), modifiers: modifiers),
                    .editing(.clipboardCommand), "keyCode=\(code), modifiers=\(modifiers)"
                )
            }
        }
    }

    func testControlOrOptionWithoutCommandDoesNotBecomeUndoOrClipboard() {
        let codes: [UInt16] = [6, 0, 8, 9, 7]
        for code in codes {
            for modifiers in editingModifiers where !modifiers.command && (modifiers.control || modifiers.option) {
                XCTAssertEqual(
                    classify(makeKey(code), modifiers: modifiers), .editing(.navigation),
                    "keyCode=\(code), modifiers=\(modifiers)"
                )
            }
        }
    }

    func testOtherCommandControlOrOptionKeysAreNavigation() {
        let codes: [UInt16] = [1, 12, 39, 47, 53, 122]
        for code in codes {
            for modifiers in editingModifiers where modifiers.command || modifiers.control || modifiers.option {
                XCTAssertEqual(
                    classify(makeKey(code, text: "z"), modifiers: modifiers), .editing(.navigation),
                    "keyCode=\(code), modifiers=\(modifiers)"
                )
            }
        }
    }

    func testLocalPhysicalKeyZeroIsPrintableWithoutUnicodeRemoteDispatch() {
        let payloads: [String?] = [nil, "", "a", "\u{0444}", " ", "\n", "\t", "\u{8}", "\u{7F}"]
        for text in payloads {
            let key = makeKey(0, text: text)
            XCTAssertNil(key.char)
            XCTAssertNil(key.forwardedText)
            XCTAssertEqual(classify(key), .printable(key))
        }
    }

    func testMappedPrintableKeysPreserveShiftCapsAndFullTypedKey() {
        for code in KeyMapping.keycodeToEN.keys.sorted() {
            for shift in [false, true] {
                for caps in [false, true] {
                    let key = makeKey(code, text: "\u{0435}\u{0301}x", shift: shift, caps: caps)
                    XCTAssertEqual(classify(key), .printable(key), "keyCode=\(code)")
                }
            }
        }
    }

    func testMappedKeysRemainPrintableWithoutProducedText() {
        for code in KeyMapping.keycodeToEN.keys.sorted() {
            let key = makeKey(code)
            XCTAssertEqual(classify(key), .printable(key), "keyCode=\(code)")
        }
    }

    func testPunctuationStaysPrintableUntilStructuralBoundary() {
        let cases: [(UInt16, String, Bool)] = [
            (43, ",", false), (47, ".", false), (44, "?", true),
            (18, "!", true), (41, ";", false), (41, ":", true),
            (39, "'", false), (39, "\"", true), (19, "@", true),
            (26, "&", true), (33, "[", false), (30, "]", false),
            (43, "\u{0431}", false), (47, "\u{044E}", false),
            (44, ",", true), (26, "?", true),
            (47, "...", false), (44, "?!", true),
        ]
        for (code, text, shift) in cases {
            let key = makeKey(code, text: text, shift: shift)
            XCTAssertEqual(classify(key), .printable(key), "keyCode=\(code), text=\(text)")
        }
    }

    func testUnrecognizedKeysInvalidateEvenWithPrintableOrBoundaryPayload() {
        // Includes Escape, F1/F12, keypad Enter, and unmapped/out-of-range codes.
        let codes: [UInt16] = [10, 52, 53, 76, 111, 122, 127, UInt16.max]
        let payloads: [String?] = [nil, "", "a", " ", "\n", "\t"]
        for code in codes {
            for text in payloads {
                XCTAssertEqual(
                    classify(makeKey(code, text: text)), .editing(.navigation), "keyCode=\(code)"
                )
            }
        }
    }

    private typealias EditingModifiers = (command: Bool, control: Bool, option: Bool)

    private let editingModifiers: [EditingModifiers] = [
        (false, false, false), (true, false, false),
        (false, true, false), (false, false, true),
        (true, true, false), (true, false, true),
        (false, true, true), (true, true, true),
    ]

    private func classify(
        _ key: TypedKey,
        modifiers: EditingModifiers = (false, false, false)
    ) -> LocalKeyDisposition {
        InputEventClassifier.classifyLocalKeyDown(
            key: key, command: modifiers.command, control: modifiers.control, option: modifiers.option
        )
    }

    private func makeKey(
        _ code: UInt16,
        text: String? = nil,
        shift: Bool = false,
        caps: Bool = false
    ) -> TypedKey {
        TypedKey(
            keyCode: code, shift: shift, caps: caps,
            producedText: text, sourceLayoutID: "test.local"
        )
    }
}
