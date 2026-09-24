import Foundation
import Observation

/// One prompt, several attempts in parallel. Each attempt is a full conversation with its own
/// engine, working in its own git worktree (seeded from the current working tree), running
/// unattended but sandboxed to that worktree. An optional check command scores each attempt;
/// you apply the one you like back to the project.
@MainActor
@Observable
final class Race: Identifiable {
    enum Check: Equatable {
        case running
        case passed(String)
        case failed(String)
    }

    struct Attempt: Identifiable {
        let id: Int
        let dir: URL
        let model: String
        let conversation: Conversation
        var check: Check?

        @MainActor var finished: Bool { conversation.turns.last?.finished ?? false }
    }

    let id = UUID()
    let prompt: String
    let checkCommand: String?
    private let base: String
    private let root: URL
    private(set) var attempts: [Attempt] = []
    private(set) var applied: Int?
    private(set) var error: String?

    private struct Created: Decodable {
        let base: String
        let dirs: [String]
    }

    private struct Applied: Decodable {
        let files: [String]
    }

    static func start(in folder: URL, prompt: String, models: [String], check: String?) async throws -> Race {
        let created = try await Frog.json(Created.self, args: ["--attempts", "\(models.count)", "--json"], cwd: folder)
        return Race(root: folder, base: created.base, prompt: prompt, dirs: created.dirs.map(URL.init(fileURLWithPath:)), models: models, check: check)
    }

    private init(root: URL, base: String, prompt: String, dirs: [URL], models: [String], check: String?) {
        self.root = root
        self.base = base
        self.prompt = prompt
        self.checkCommand = check.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        for (i, (dir, model)) in zip(dirs, models).enumerated() {
            let c = Conversation(folder: dir, arguments: ["--yolo", "--sandbox"], model: model)
            c.onSessionChange = { [weak self] in self?.update(i) }
            // Queued until the engine is ready.
            c.submit(prompt)
            attempts.append(Attempt(id: i, dir: dir, model: model, conversation: c))
        }
    }

    var allFinished: Bool { attempts.allSatisfy(\.finished) }

    private func update(_ i: Int) {
        guard attempts.indices.contains(i), attempts[i].finished, attempts[i].check == nil else { return }
        guard let command = checkCommand else { return }
        attempts[i].check = .running
        let dir = attempts[i].dir
        Task {
            let result = await Self.run(command, in: dir)
            attempts[i].check = result
        }
    }

    private nonisolated static func run(_ command: String, in dir: URL) async -> Check {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = dir
            p.environment = Frog.environment
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return .failed("couldn't run the check") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data.suffix(4000), as: UTF8.self)
            return p.terminationStatus == 0 ? .passed(text) : .failed(text)
        }.value
    }

    /// Apply attempt `i` to the project and clean up every worktree.
    func apply(_ i: Int) async -> Bool {
        guard attempts.indices.contains(i) else { return false }
        do {
            _ = try await Frog.json(
                Applied.self,
                args: ["--apply-attempt", attempts[i].dir.path, "--base", base],
                cwd: root
            )
            applied = i
            discard()
            return true
        } catch {
            self.error = "Couldn't apply attempt \(i + 1): \(error.localizedDescription)"
            return false
        }
    }

    /// Stop every attempt and remove the worktrees.
    func discard() {
        for a in attempts { a.conversation.stop() }
        let dirs = attempts.flatMap { ["--discard-attempt", $0.dir.path] }
        let root = root
        Task.detached {
            try? await Task.sleep(for: .seconds(1.5))
            guard let bin = Frog.binary else { return }
            let p = Process()
            p.executableURL = bin
            p.arguments = dirs
            p.currentDirectoryURL = root
            try? p.run()
            p.waitUntilExit()
        }
    }
}
