import XCTest
@testable import Frog

/// The where menu's repo order against the shared vectors (docs/design/composer/repo-rank.json).
/// The web's apps/web/test/repo-rank.test.ts runs the same file against repoRank.ts.
final class RepoRankTests: XCTestCase {
    private struct Doc: Decodable {
        struct Repo: Decodable { let name: String; let pushed_at: String? }
        struct Case: Decodable {
            let name: String
            let current: String?
            let used: [String]
            let repos: [Repo]
            let query: String
            let ranked: [String]
            let shown: [String]
            let more: Int
            let line: String?
        }
        let limit: Int
        let cases: [Case]
    }

    private func doc() throws -> Doc {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/design/composer/repo-rank.json")
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    func testTheSharedVectors() throws {
        let doc = try doc()
        XCTAssertEqual(RepoRank.limit, doc.limit)
        XCTAssertFalse(doc.cases.isEmpty)
        for c in doc.cases {
            let ranked = RepoRank.rank(current: c.current, used: c.used, repos: c.repos.map { ($0.name, $0.pushed_at) })
            XCTAssertEqual(ranked, c.ranked, c.name)
            let (shown, more) = RepoRank.pick(ranked, query: c.query)
            XCTAssertEqual(shown, c.shown, c.name)
            XCTAssertEqual(more, c.more, c.name)
            XCTAssertEqual(RepoRank.moreLine(more, searching: !c.query.trimmingCharacters(in: .whitespaces).isEmpty), c.line, c.name)
        }
    }

    func testUsedReposGoByTheLastTurnElseTheLastUpdate() {
        XCTAssertEqual(RepoRank.used([
            ("ecto/old", 50, nil), ("ecto/new", 10, 90), ("", 99, nil), ("ecto/old", 5, 6), ("ecto/mid", 70, nil),
        ]), ["ecto/new", "ecto/mid", "ecto/old"])
    }

    /// The gateway's repo list carries `pushed_at`; an older gateway without it still decodes.
    func testReposDecodeWithAndWithoutPushedAt() throws {
        let with = try JSONDecoder().decode(CloudGateway.Repos.self, from: Data(#"{"repos":[{"name":"a/b","private":false,"pushed_at":"2026-11-18T00:00:00Z"}],"install":null}"#.utf8))
        XCTAssertEqual(with.repos.first?.pushed_at, "2026-11-18T00:00:00Z")
        let without = try JSONDecoder().decode(CloudGateway.Repos.self, from: Data(#"{"repos":[{"name":"a/b","private":true}],"install":null}"#.utf8))
        XCTAssertNil(without.repos.first?.pushed_at)
    }
}
