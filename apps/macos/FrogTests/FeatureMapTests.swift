import Foundation
import XCTest

/// The feature map's coverage is computed from the tests (docs/testing/feature-map): a flow test
/// is named `test_<flow_id>[__variant]`, and `coverage.py --check` fails when a test names a flow
/// that doesn't exist or the map's `flow_tests` are stale. Run here so CI's test run runs it.
final class FeatureMapTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()   // FrogTests → apps/macos
        .deletingLastPathComponent().deletingLastPathComponent()   // → apps → repo
    private static let script = repo.appendingPathComponent("docs/testing/feature-map/coverage.py")

    private func run(_ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.script.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testMapMatchesTheFlowTests() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.script.path), "no checkout at \(Self.repo.path)")
        let r = try run(["--check"])
        XCTAssertEqual(r.status, 0, r.out)
    }

    /// The check itself: a test naming a flow that isn't in the map fails it, by name; a known
    /// one passes once `--write` has stored it.
    func testCheckCatchesAnUnknownFlow() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.script.path), "no checkout at \(Self.repo.path)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("feature-map-\(UUID().uuidString)")
        let tests = dir.appendingPathComponent("tests"), map = dir.appendingPathComponent("map")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let flow = #"{"area": "x", "features": [{"id": "f", "flows": [{"id": "rename-from-title", "automatable": "yes"}]}]}"#
        try flow.write(to: map.appendingPathComponent("shell.json"), atomically: true, encoding: .utf8)
        for name in ["conversation.json", "platform.json"] {
            try #"{"area": "x", "features": []}"#.write(to: map.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let file = tests.appendingPathComponent("T.swift")
        let fn = "func " + "test_"   // split, so this file declares no flow itself

        try (fn + "rename_from_title__viaMenu() {}\nfunc testOther() {}").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(try run(["--check", "--map", map.path, "--tests", tests.path]).status, 0, "stale until written")
        XCTAssertEqual(try run(["--write", "--map", map.path, "--tests", tests.path]).status, 0)
        let ok = try run(["--check", "--map", map.path, "--tests", tests.path])
        XCTAssertEqual(ok.status, 0, ok.out)
        XCTAssertTrue(ok.out.contains("1 of 1 marked automatable"), ok.out)

        try (fn + "rename_from_tilte() {}").write(to: file, atomically: true, encoding: .utf8)
        let bad = try run(["--check", "--map", map.path, "--tests", tests.path])
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.out.contains("T.swift:test_rename_from_tilte names flow rename-from-tilte, which isn't in the map"), bad.out)
    }
}
