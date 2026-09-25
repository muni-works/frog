import AppKit
@preconcurrency import AVFoundation

/// Three tiny sounds the frog makes, synthesized when first needed (nothing is bundled): a plip
/// when you send, a ribbit when a turn finishes, a drip when it needs permission. Off unless
/// "Frog sounds" is on; quiet; and only while the app is in front, or in the background when
/// finished-turn notifications are on.
@MainActor
final class FrogSounds {
    static let shared = FrogSounds()

    enum Cue { case plip, ribbit, drip }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate: Double = 44100
    private var prepared = false
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]

    func play(_ cue: Cue) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "playfulSounds") else { return }
        guard NSApp.isActive || defaults.object(forKey: "notifyWhenDone") as? Bool ?? true else { return }
        guard prepare(), let buffer = buffer(for: cue) else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil)
    }

    private var format: AVAudioFormat? { AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) }

    private func prepare() -> Bool {
        if !prepared {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.3
            prepared = true
        }
        if !engine.isRunning { try? engine.start() }
        return engine.isRunning
    }

    private func buffer(for cue: Cue) -> AVAudioPCMBuffer? {
        if let b = buffers[cue] { return b }
        let samples: [Float]
        switch cue {
        case .plip: samples = tone(ms: 60) { t in (sin(2 * .pi * (1200 - 500 * t) * t)) * exp(-t * 60) }
        case .ribbit:
            // Two short low notes with a touch of second harmonic, so it croaks rather than beeps.
            samples = tone(ms: 150) { t in
                let f: Double = t < 0.075 ? 210 : 170
                let a = t < 0.075 ? exp(-t * 25) : exp(-(t - 0.075) * 25)
                return (sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)) * a * 0.8
            }
        case .drip: samples = tone(ms: 120) { t in sin(2 * .pi * (1800 - 1300 * t / 0.12) * t) * exp(-t * 35) }
        }
        guard let format, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = b.floatChannelData else { return nil }
        for (i, s) in samples.enumerated() { data[0][i] = s }
        b.frameLength = AVAudioFrameCount(samples.count)
        buffers[cue] = b
        return b
    }

    /// Samples of `f(t)` for `ms` milliseconds at low amplitude, with a 2ms fade-in against clicks.
    private func tone(ms: Double, _ f: (Double) -> Double) -> [Float] {
        let n = Int(rate * ms / 1000)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let fade = min(1, t / 0.002)
            return Float(f(t) * fade * 0.35)
        }
    }
}
