import XCTest
@testable import Frog

/// ComposerModel against the shared vectors (docs/design/composer/cases.json). The web's
/// apps/web/test/composer.test.ts runs the same file against composer.ts: a behaviour change is
/// a new case there, and both fail until they agree.
final class ComposerReducerTests: XCTestCase {

    private struct Doc: Decodable {
        struct Case: Decodable { let name: String; let given: JSON; let intent: JSON; let expect: JSON; let effects: JSON }
        let base: JSON
        let cases: [Case]
    }

    private func doc() throws -> Doc {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/composer/cases.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    /// Objects merge, arrays and scalars replace.
    private func merge(_ a: JSON, _ b: JSON) -> JSON {
        guard case .object(var out) = a, case .object(let over) = b else { return b }
        for (k, v) in over { out[k] = out[k].map { merge($0, v) } ?? v }
        return .object(out)
    }

    /// Partial match: objects match the listed keys (missing is null), arrays match length and
    /// each element.
    private func match(_ actual: JSON, _ want: JSON, _ path: String) -> String? {
        switch want {
        case .object(let w):
            guard case .object(let a) = actual else { return "\(path): wanted an object, got \(actual)" }
            for (k, v) in w.sorted(by: { $0.key < $1.key }) {
                if let m = match(a[k] ?? .null, v, "\(path).\(k)") { return m }
            }
            return nil
        case .array(let w):
            guard case .array(let a) = actual, a.count == w.count else { return "\(path): wanted \(want), got \(actual)" }
            for (i, v) in w.enumerated() {
                if let m = match(a[i], v, "\(path)[\(i)]") { return m }
            }
            return nil
        default:
            return actual == want ? nil : "\(path): wanted \(want), got \(actual)"
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: JSON) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
    }

    func testTheSharedCasesCoverThePlan() throws {
        let cases = try doc().cases
        XCTAssertGreaterThanOrEqual(cases.count, 60)
        XCTAssertEqual(Set(cases.map(\.name)).count, cases.count, "names are unique")
    }

    func testEverySharedCase() throws {
        let d = try doc()
        var failures: [String] = []
        for c in d.cases {
            let given = try decode(ComposerModel.State.self, merge(d.base, c.given))
            let intent = try decode(ComposerModel.Intent.self, c.intent)
            let (next, effects) = ComposerModel.reduce(given, intent)
            guard case .object(var got) = JSON(next) else { return XCTFail("state didn't encode") }
            got["derived"] = JSON(ComposerModel.derive(next))
            if let m = match(.object(got), c.expect, "state") ?? match(JSON(effects), c.effects, "effects") {
                failures.append("\(c.name): \(m)")
            }
        }
        XCTAssert(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
