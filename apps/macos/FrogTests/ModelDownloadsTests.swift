import XCTest
@testable import Frog

/// Downloads a tiny public repo into a temporary cache and checks the layout tang-llm reads.
/// Needs the network; skipped when Hugging Face isn't reachable.
@MainActor
final class ModelDownloadsTests: XCTestCase {
    func testDownloadsIntoHuggingFaceCacheLayout() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "frog-hf-\(UUID().uuidString)")
        setenv("HF_HUB_CACHE", cache.path, 1)
        defer {
            unsetenv("HF_HUB_CACHE")
            try? FileManager.default.removeItem(at: cache)
        }
        let repo = "hf-internal-testing/tiny-random-LlamaForCausalLM"
        let downloads = ModelDownloads.shared
        downloads.download(repo)
        var finished = false
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(100))
            switch downloads.states[repo] {
            case .done: finished = true
            case .failed(let e):
                throw XCTSkip("Hugging Face unreachable: \(e)")
            default: continue
            }
            if finished { break }
        }
        XCTAssertTrue(finished, "download didn't finish")
        XCTAssertTrue(ModelDownloads.isInstalled(repo))
        let dir = ModelDownloads.repoDir(repo)
        let sha = try String(contentsOf: dir.appending(path: "refs/main"), encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "snapshots/\(sha)/config.json").path))
    }
}
