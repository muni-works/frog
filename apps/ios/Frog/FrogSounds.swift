@preconcurrency import AVFoundation
import Foundation

/// The Mac's three frog sounds, synthesized the same way (nothing is bundled): a plip when you
/// send, a ribbit when a turn finishes, a drip when frog needs you. Ambient, so the silent
/// switch mutes them and they never interrupt your music. On unless turned off in Settings.
@MainActor
final class FrogSounds {
    static let shared = FrogSounds()

    enum Cue { case plip, ribbit, drip }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "playfulSounds") as? Bool ?? true
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate: Double = 44100
    private var prepared = false
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]

    func play(_ cue: Cue) {
        guard Self.enabled, prepare(), let buffer = buffer(for: cue) else { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil)
    }

    private var format: AVAudioFormat? { AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) }

    private func prepare() -> Bool {
        if !prepared {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
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
        case .plip: samples = tone(ms: 60) { t in sin(2 * .pi * (1200 - 500 * t) * t) * exp(-t * 60) }
        case .ribbit:
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

    private func tone(ms: Double, _ f: (Double) -> Double) -> [Float] {
        let n = Int(rate * ms / 1000)
        return (0..<n).map { i in
            let t = Double(i) / rate
            return Float(f(t) * min(1, t / 0.002) * 0.35)
        }
    }
}
