import XCTest
@testable import Frog

/// The picker's price line. Frog Cloud lists prices in dollars per **million** tokens, and
/// `ModelStats.Prices` holds them in that unit already (`catalog::per_million` converts the
/// gateway's per-token string once, at parse time). The picker multiplied by a second 1,000,000
/// and showed "$1440000.00/M out" for a model that costs $1.44.
final class ModelPriceTests: XCTestCase {
    /// The three Frog Cloud models, at the prices the gateway lists today.
    func testFrogCloudPricesReadAsPerMillionDollars() {
        XCTAssertEqual(ModelMenu.priceLine(1.44), "$1.44/M out", "DeepSeek V4.1 Flash")
        XCTAssertEqual(ModelMenu.priceLine(0.60), "$0.60/M out", "GLM-5.3 Flash")
        XCTAssertEqual(ModelMenu.priceLine(1.50), "$1.50/M out", "Qwen3 Coder Next")
    }

    /// The bug, pinned by its own number: a price must never render in the millions for a model
    /// that costs single-digit dollars per million.
    func testAPriceIsNeverScaledTwice() {
        let line = ModelMenu.priceLine(1.44)
        XCTAssertEqual(line, "$1.44/M out")
        XCTAssertFalse(line!.contains("1440000"), "the price was multiplied by 1,000,000 twice")
    }

    /// A model with no output price has no line at all, rather than "$0.00/M out".
    func testNoPriceMeansNoLine() {
        XCTAssertNil(ModelMenu.priceLine(0))
        XCTAssertNil(ModelMenu.priceLine(-1), "-1 is the engine's \"not listed\"")
    }
}
