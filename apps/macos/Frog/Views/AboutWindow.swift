import AppKit
import SwiftUI

/// The About window: the standard panel's icon, name, version and copyright, plus a frog
/// that answers when poked. Poke it enough and it gets hungry.
struct AboutView: View {
    private static let quips = [
        "ribbit.", "ribbit?", "RIBBIT.", "hop hop.", "i'm busy shipping.",
        "tokens go brrr.", "plip.", "that tickles.", "croak.", "lily pad sold separately.",
    ]
    /// Pokes in a row that wake the flies.
    private static let hungry = 7

    @State private var pokes = 0
    @State private var hop = false
    @State private var quip: String?
    @State private var quipTask: Task<Void, Never>?
    @State private var flies: [Fly] = []
    @State private var eaten = 0
    @State private var flyStart = Date.now

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                ZStack(alignment: .top) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .scaleEffect(x: hop ? 1.08 : 1, y: hop ? 0.86 : 1, anchor: .bottom)
                        .offset(y: hop ? -14 : 0)
                        .onTapGesture(perform: poke)
                        .help("poke")
                    if let quip {
                        Text(quip)
                            .font(.frog(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.green.opacity(0.85), in: Capsule())
                            .foregroundStyle(.black)
                            .offset(x: 70, y: -6)
                            .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .padding(.top, 8)
                Text("Frog").font(.frog(size: 20, weight: .bold))
                Text(version).font(.frog(size: 13))
                    .foregroundStyle(.secondary)
                Text(flies.isEmpty && eaten > 0 ? "flies eaten: \(eaten) 🐸" : copyright)
                    .font(.frog(size: 13))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .frame(width: 280, height: 260)

            // The swarm: each fly wanders on its own path; click one to eat it.
            TimelineView(.animation(paused: flies.isEmpty)) { timeline in
                let t = timeline.date.timeIntervalSince(flyStart)
                ZStack {
                    ForEach(flies) { fly in
                        Text("🪰")
                            .font(.system(size: 16))
                            .position(fly.position(at: t))
                            .onTapGesture { eat(fly) }
                    }
                }
            }
            .frame(width: 280, height: 260)
            .allowsHitTesting(!flies.isEmpty)
        }
        .background(FrogCanvas.color)
    }

    private func poke() {
        pokes += 1
        FrogSounds.shared.play(.ribbit)
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { hop = true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.45).delay(0.14)) { hop = false }

        if pokes % Self.hungry == 0, flies.isEmpty {
            say("i'm hungry.")
            flyStart = .now
            eaten = 0
            flies = (0..<5).map { _ in Fly() }
        } else {
            say(Self.quips.randomElement()!)
        }
    }

    private func eat(_ fly: Fly) {
        FrogSounds.shared.play(.plip)
        withAnimation(.easeOut(duration: 0.15)) { flies.removeAll { $0.id == fly.id } }
        eaten += 1
        withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { hop = true }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.45).delay(0.14)) { hop = false }
        say(flies.isEmpty ? "full. thank you." : "chomp.")
    }

    private func say(_ line: String) {
        quipTask?.cancel()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { quip = line }
        quipTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { quip = nil }
        }
    }
}

/// A fly on a wobbly Lissajous loop around the window.
private struct Fly: Identifiable {
    let id = UUID()
    private let cx = Double.random(in: 90...190)
    private let cy = Double.random(in: 70...170)
    private let rx = Double.random(in: 40...90)
    private let ry = Double.random(in: 30...70)
    private let fx = Double.random(in: 0.6...1.4)
    private let fy = Double.random(in: 0.8...1.8)
    private let phase = Double.random(in: 0...(2 * .pi))

    func position(at t: Double) -> CGPoint {
        let jitter = sin(t * 23 + phase) * 2
        return CGPoint(x: cx + rx * sin(t * fx + phase) + jitter,
                       y: cy + ry * sin(t * fy + phase * 1.7) + jitter)
    }
}
