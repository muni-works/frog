import Foundation
import Observation

/// An open-weights model we suggest, runnable by the tang sidecar.
struct SuggestedModel: Identifiable, Hashable {
    let repo: String
    let title: String
    let detail: String
    let approxGB: Double

    var id: String { repo }
    var spec: String { "\(ProviderID.local)/\(repo)" }

    static let all: [SuggestedModel] = [
        SuggestedModel(repo: "mlx-community/Qwen3-4B-4bit", title: "Qwen3 4B",
                       detail: "Best balance for coding on most Macs", approxGB: 2.3),
        SuggestedModel(repo: "mlx-community/Qwen3-8B-4bit", title: "Qwen3 8B",
                       detail: "Stronger, needs 16 GB of memory", approxGB: 4.6),
        SuggestedModel(repo: "mlx-community/Qwen3-32B-4bit", title: "Qwen3 32B",
                       detail: "Best local quality, needs 48 GB of memory", approxGB: 18.0),
        SuggestedModel(repo: "mlx-community/Qwen3-1.7B-4bit", title: "Qwen3 1.7B",
                       detail: "Fastest, for quick questions", approxGB: 1.0),
        SuggestedModel(repo: "mlx-community/gemma-3-4b-it-4bit", title: "Gemma 3 4B",
                       detail: "Sees images: screenshots, diagrams, photos", approxGB: 3.4),
    ]
}

/// Downloads Hugging Face repos into the standard cache (`~/.cache/huggingface/hub`), where
/// tang-llm and `frog --models` look. Files land as plain files in `snapshots/<commit>/`, and
/// `refs/main` records the commit, like the official client's layout.
@MainActor
@Observable
final class ModelDownloads {
    static let shared = ModelDownloads()

    enum State: Equatable {
        case downloading(fraction: Double)
        case failed(String)
        case done
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    static var hub: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HF_HUB_CACHE"] { return URL(fileURLWithPath: p) }
        if let p = env["HF_HOME"] { return URL(fileURLWithPath: p).appending(path: "hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }

    static func repoDir(_ repo: String) -> URL {
        hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
    }

    /// Whether a complete snapshot that tang can load is already on disk.
    static func isInstalled(_ repo: String) -> Bool {
        let snaps = repoDir(repo).appending(path: "snapshots")
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil)) ?? []
        return dirs.contains { d in
            let files = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            return files.contains("config.json")
                && files.contains("tokenizer.json")
                && files.contains("tokenizer_config.json")
                && files.contains { $0.hasSuffix(".safetensors") }
        }
    }

    func download(_ repo: String) {
        guard tasks[repo] == nil else { return }
        states[repo] = .downloading(fraction: 0)
        tasks[repo] = Task {
            do {
                try await fetch(repo)
                states[repo] = .done
            } catch is CancellationError {
                states[repo] = nil
            } catch {
                states[repo] = .failed(error.localizedDescription)
            }
            tasks[repo] = nil
        }
    }

    /// Delete a downloaded model from the cache.
    func remove(_ repo: String) {
        cancel(repo)
        try? FileManager.default.removeItem(at: Self.repoDir(repo))
        states[repo] = nil
    }

    func cancel(_ repo: String) {
        tasks[repo]?.cancel()
    }

    private struct Info: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }
        let sha: String
        let siblings: [Sibling]
    }

    private static func wanted(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".safetensors") || n.hasSuffix(".json") || n.hasSuffix(".txt")
            || n.hasSuffix(".jinja") || n == "tokenizer.model"
    }

    private func fetch(_ repo: String) async throws {
        let api = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face didn't find \(repo)"])
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        let files = info.siblings.filter { Self.wanted($0.rfilename) }
        let total = max(1, files.reduce(0) { $0 + ($1.size ?? 0) })
        let dir = Self.repoDir(repo)
        let snapshot = dir.appending(path: "snapshots/\(info.sha)")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)

        var finished: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let dest = snapshot.appending(path: file.rfilename)
            if let size = file.size,
               let have = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64,
               have == size {
                finished += size
                continue
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(info.sha)/\(file.rfilename)")!
            let base = finished
            try await Self.download(url, to: dest) { [weak self] received in
                self?.states[repo] = .downloading(fraction: Double(base + received) / Double(total))
            }
            finished += file.size ?? 0
        }
        let refs = dir.appending(path: "refs")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try info.sha.write(to: refs.appending(path: "main"), atomically: true, encoding: .utf8)
    }

    /// One file, reporting bytes received as it goes; cancellable.
    private static func download(_ url: URL, to dest: URL, progress: @escaping @MainActor (Int64) -> Void) async throws {
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if let t = active[url] { progress(t.countOfBytesReceived) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { poll.cancel() }
        let temp: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let t = URLSession.shared.downloadTask(with: url) { location, response, error in
                    if let error { return cont.resume(throwing: error) }
                    guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                        return cont.resume(throwing: URLError(.badServerResponse))
                    }
                    // The system deletes `location` when this returns: move it somewhere of ours.
                    let keep = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: keep)
                        cont.resume(returning: keep)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                Self.active[url] = t
                t.resume()
            }
        } onCancel: {
            Task { @MainActor in active[url]?.cancel() }
        }
        active[url] = nil
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
    }

    private static var active: [URL: URLSessionDownloadTask] = [:]
}
