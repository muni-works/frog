import AppKit
@preconcurrency import AVFoundation
import Speech

/// Voice input for the composer, transcribed on this Mac with SpeechAnalyzer: audio never
/// leaves it. Streams what's been said to `show` as it firms up, until stopped.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        /// Asking for access, loading the speech model.
        case starting
        /// Fetching the speech model for this language (0...1).
        case downloading(Double)
        case listening
        /// Stopped listening; settling the last words.
        case finishing
    }

    private(set) var phase = Phase.idle
    /// Microphone loudness, 0...1, while listening.
    private(set) var level: Float = 0
    /// Why dictation couldn't start or stopped early; shown under the field until dismissed.
    var problem: DictationProblem?

    var isActive: Bool { phase != .idle }

    private var task: Task<Void, Never>?
    /// Bumped per start, so a stale run or timer can't end a newer one.
    private var session = 0
    private var mic: Microphone?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var transcript = DictationTranscript()
    /// Puts the transcript in the field; false when the field no longer has room for it (the
    /// text was sent, cleared or edited over), which ends dictation.
    private var show: ((DictationTranscript) -> Bool)?
    private var done: (() -> Void)?

    func start(show: @escaping (DictationTranscript) -> Bool, done: @escaping () -> Void) {
        guard phase == .idle else { return }
        problem = nil
        transcript = DictationTranscript()
        self.show = show
        self.done = done
        phase = .starting
        session += 1
        task = Task { await run() }
    }

    /// Stop listening and put in the last words once they settle.
    func stop() {
        switch phase {
        case .idle, .finishing: return
        case .starting, .downloading: cancel()
        case .listening:
            phase = .finishing
            level = 0
            mic?.stop()
            input?.finish()
            let analyzer = analyzer
            Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
            // Don't hang on the last words if the analyzer never finishes.
            let current = session
            Task {
                try? await Task.sleep(for: .seconds(5))
                if session == current, phase == .finishing { cancel() }
            }
        }
    }

    /// Stop now, leaving the field as it is (words not yet settled stay as shown).
    func cancel() {
        guard phase != .idle else { return }
        show = nil
        mic?.stop()
        input?.finish()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        task?.cancel()
        finish()
    }

    private func run() async {
        do {
            try await Self.authorize()
            let module = try await Self.module()
            try await install(module)
            try Task.checkCancellation()
            try await listen(module)
        } catch is CancellationError {
        } catch let p as DictationProblem {
            problem = p
        } catch {
            problem = .failed(error.localizedDescription)
        }
        // A cancelled run was already finished by `cancel`, maybe before a newer one started.
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        guard phase != .idle else { return }
        phase = .idle
        level = 0
        mic?.stop()
        mic = nil
        input?.finish()
        input = nil
        analyzer = nil
        show = nil
        task = nil
        done?()
        done = nil
    }

    /// Transcribe the microphone until the analyzer finishes (stopped, or cancelled).
    private func listen(_ module: any SpeechModule) async throws {
        let mic = Microphone()
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: mic.format)
        guard let format else { throw DictationProblem.failed("No audio format the speech model accepts.") }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try Task.checkCancellation()
        try mic.start(converting: format, into: input) { [weak self] level in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                self.level = level
            }
        }
        self.mic = mic
        self.input = input
        self.analyzer = analyzer
        phase = .listening
        try await analyzer.start(inputSequence: stream)
        if let t = module as? SpeechTranscriber {
            for try await r in t.results {
                guard receive(String(r.text.characters), isFinal: r.isFinal) else { break }
            }
        } else if let t = module as? DictationTranscriber {
            for try await r in t.results {
                guard receive(String(r.text.characters), isFinal: r.isFinal) else { break }
            }
        }
    }

    /// One result from the recognizer. False to stop.
    private func receive(_ text: String, isFinal: Bool) -> Bool {
        guard let show else { return false }
        transcript.apply(text, isFinal: isFinal)
        guard show(transcript) else {
            cancel()
            return false
        }
        return true
    }

    /// The speech model for the Mac's language: SpeechTranscriber (long-form, on-device), or
    /// the dictation model on Macs that can't run it.
    private static func module() async throws -> any SpeechModule {
        let preferred = Locale.current
        if SpeechTranscriber.isAvailable {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) else {
                throw DictationProblem.unsupported(preferred)
            }
            return SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) else {
            throw DictationProblem.unsupported(preferred)
        }
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    /// Download the speech model for this language if it isn't on the Mac yet, with progress.
    private func install(_ module: any SpeechModule) async throws {
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        phase = .downloading(0)
        let progress = request.progress
        let current = session
        let poll = Task {
            while !Task.isCancelled {
                if session == current, case .downloading = phase { phase = .downloading(progress.fractionCompleted) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poll.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw DictationProblem.download(error.localizedDescription)
        }
        try Task.checkCancellation()
        phase = .starting
    }

    /// Microphone access, and speech recognition for good measure (transcription stays on-device
    /// either way).
    private static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationProblem.microphoneDenied }
        default: throw DictationProblem.microphoneDenied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            guard await requestSpeech() == .authorized else { throw DictationProblem.speechDenied }
        default: throw DictationProblem.speechDenied
        }
    }

    /// Off the main actor: the callback arrives on a background queue.
    private nonisolated static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
    }
}

enum DictationProblem: Error, Equatable {
    case microphoneDenied
    case speechDenied
    case noMicrophone
    case unsupported(Locale)
    case download(String)
    case failed(String)

    var message: String {
        switch self {
        case .microphoneDenied: "Kiln needs microphone access to take dictation."
        case .speechDenied: "Kiln needs speech recognition access to take dictation. It runs on this Mac."
        case .noMicrophone: "No microphone found."
        case .unsupported(let l):
            "On-device dictation doesn't support \(l.localizedString(forIdentifier: l.identifier) ?? l.identifier) yet."
        case .download(let e): "Couldn't download the speech model: \(e)"
        case .failed(let e): "Dictation stopped: \(e)"
        }
    }

    /// The System Settings pane that fixes it, if one does.
    var settings: URL? {
        switch self {
        case .microphoneDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        default: nil
        }
    }
}

/// The default input device, feeding the analyzer in its format. Runs its tap on the audio
/// thread, so it stays off the main actor.
private final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var tapped = false

    /// What the input device records.
    var format: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start(converting to: AVAudioFormat, into input: AsyncStream<AnalyzerInput>.Continuation,
               level: @escaping @Sendable (Float) -> Void) throws {
        let node = engine.inputNode
        let from = node.outputFormat(forBus: 0)
        guard from.sampleRate > 0, from.channelCount > 0 else { throw DictationProblem.noMicrophone }
        let converter = from == to ? nil : AVAudioConverter(from: from, to: to)
        node.installTap(onBus: 0, bufferSize: 2048, format: from) { buffer, _ in
            level(Self.level(of: buffer))
            let out: AVAudioPCMBuffer? = if let converter { Self.convert(buffer, with: converter, to: to) } else { buffer }
            if let out { input.yield(AnalyzerInput(buffer: out)) }
        }
        tapped = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw DictationProblem.failed(error.localizedDescription)
        }
    }

    func stop() {
        if tapped { engine.inputNode.removeTap(onBus: 0) }
        tapped = false
        engine.stop()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// Loudness of a buffer, 0...1, from its RMS in decibels (-50 dB is silence).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 50))
    }
}
