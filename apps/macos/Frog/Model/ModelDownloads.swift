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

    /// A download's size as Settings › Models writes a machine's memory: whole gigabytes from 10
    /// up ("18 GB"), one decimal below ("4.6 GB").
    static func gbText(_ g: Double) -> String {
        g >= 10 ? "\(Int(g.rounded())) GB" : String(format: "%.1f GB", g)
    }

    /// The models the composer's menu offers on This Mac before they're downloaded: the
    /// catalog's `menu` entries (catalog/local-models.json), in its order, so the menu and
    /// Settings › Models name and size them the same.
    static let all: [SuggestedModel] = LocalCatalog.all.filter { $0.menu == true && $0.runs_on.contains("metal") }.map {
        SuggestedModel(repo: $0.source.repo, title: $0.name, detail: LocalCatalog.usesLine($0),
                       approxGB: Double($0.download_bytes) / 1e9)
    }
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
    /// Bytes so far, of how many, and the rate, by repo: Settings › Models' progress row.
    private(set) var progress: [String: (done: Int64, total: Int64, rate: Double?, at: Date)] = [:]
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
                progress[repo] = nil
                states[repo] = .done
            } catch is CancellationError {
                progress[repo] = nil
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
                guard let self else { return }
                let done = base + received, now = Date()
                var rate = progress[repo]?.rate
                if let prev = progress[repo], done > prev.done, now.timeIntervalSince(prev.at) > 0 {
                    let fresh = Double(done - prev.done) / now.timeIntervalSince(prev.at)
                    rate = rate.map { 0.8 * $0 + 0.2 * fresh } ?? fresh
                }
                if progress[repo]?.done != done { progress[repo] = (done, total, rate, now) }
                states[repo] = .downloading(fraction: Double(done) / Double(total))
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
