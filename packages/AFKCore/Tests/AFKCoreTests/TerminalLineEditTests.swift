import XCTest
@testable import AFKCore

final class TerminalLineEditTests: XCTestCase {
    func testTypingAppendsOnlyNewText() {
        XCTAssertEqual(TerminalLineEdit.bytes(from: "", to: "ls"), Data("ls".utf8))
        XCTAssertEqual(TerminalLineEdit.bytes(from: "ls", to: "ls -la"), Data(" -la".utf8))
    }
    func testDictationCorrectionRewritesOnlyTheChangedTail() {
        // "git status" heard as "get status" first, then corrected.
        XCTAssertEqual(TerminalLineEdit.bytes(from: "get status", to: "git status"),
                       Data(repeating: 0x7f, count: 9) + Data("it status".utf8))
    }
    func testDeletingAndUnchangedText() {
        XCTAssertEqual(TerminalLineEdit.bytes(from: "ls -la", to: "ls"), Data(repeating: 0x7f, count: 4))
        XCTAssertEqual(TerminalLineEdit.bytes(from: "pwd", to: "pwd"), Data())
    }
    func testCountsCodePointsNotBytes() {
        // One backspace per code point, as zle and readline erase: é, space, 👋 and 🏽.
        XCTAssertEqual(TerminalLineEdit.bytes(from: "café 👋🏽", to: "caf"), Data(repeating: 0x7f, count: 4))
        XCTAssertEqual(TerminalLineEdit.bytes(from: "cafe", to: "café"), Data([0x7f]) + Data("é".utf8))
    }
    func testSmartPunctuationBecomesShellText() {
        XCTAssertEqual(TerminalLineEdit.plain("git log —oneline && echo “hi” ‘x’"), "git log --oneline && echo \"hi\" 'x'")
    }
}
