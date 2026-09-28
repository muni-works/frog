import XCTest
@testable import Frog

final class MarkdownTests: XCTestCase {
    func testPipeTableParses() {
        let md = """
        Intro
        | Name | Type | Note |
        |------|:----:|-----:|
        | Gregorian | Solar | most of the world |
        | Julian | Solar |
        """
        let blocks = Markdown.parse(md)
        XCTAssertEqual(blocks.count, 2)
        guard case .table(let header, let align, let rows) = blocks[1] else { return XCTFail("no table") }
        XCTAssertEqual(header, ["Name", "Type", "Note"])
        XCTAssertEqual(align, [.leading, .center, .trailing])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1], ["Julian", "Solar"])
    }

    func testPipesInCodeStay() {
        XCTAssertEqual(Markdown.tableRow("| `a|b` | c |"), ["`a|b`", "c"])
        XCTAssertNil(Markdown.tableRow("not a row"))
    }

    func testHeaderWithoutAlignmentIsAParagraph() {
        let blocks = Markdown.parse("| a | b |\n| c | d |")
        XCTAssertEqual(blocks.count, 1)
        if case .table = blocks[0] { XCTFail("no alignment row, so not a table") }
    }
}
