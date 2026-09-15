// CarPlayVoiceSearchController.swift
// "Ask To Siri" — CarPlay-only voice destination search.
//
// The driver taps the mic map button, speaks a destination, and the
// transcript is handed to the SAME CarPlay flow the keyboard uses:
// results list -> trip preview -> Start. The driver always picks the
// destination; nothing auto-navigates.
//
// Audio-input policy (user requirement): prefer the CAR's microphone
// (`.carAudio` port) when one exists; fall back to the session default
// (phone mic / Bluetooth kit) only when no car mic is exposed.
//
// Transcription uses the iOS 26 SpeechAnalyzer/SpeechTranscriber API —
// fully on-device, no server round trip. Speedio's CarPlay stack is
// already gated to iOS 26+ (AppDelegate.isCarPlaySupported), so no
// SFSpeechRecognizer fallback is needed.

import AVFoundation
import CarPlay
import QuartzCore
import Speech

// MARK: - CarPlayVoiceSearchController

@MainActor
final class CarPlayVoiceSearchController {

    // Injected CarPlay context.
    private weak var interfaceController: CPInterfaceController?
    private weak var root: CarPlayNavigationRootTemplate?
    private weak var viewModel: DriveViewModel?

    // Audio / transcription state.
    private var audioSession: AVAudioSession?
    private var audioEngine: AVAudioEngine?
    // The SpeechAnalyzer type is iOS 26+, but this class compiles against the
    // 18.4 deployment target. Stored as Any so the property declaration is
    // legal; every use casts inside an availability guard.
    private var analyzerHandle: Any?
    private var resultsTask: Task<Void, Never>?
    // True until a results-drain task actually exists, so a Stop during the
    // mic-open delay never waits on a drain that will never report.
    private var resultsTaskDone = true
    private var routeChangeObserver: NSObjectProtocol?
    private var silenceTimer: Timer?
    private var hardCapTimer: Timer?
    private var isFinalizing = false

    // Thread-safe boxes shared with the nonisolated audio tap.
    private let finalBox = FinalTranscriptBox()
    private let levelGate = AudioLevelGate(gateDB: -38.0)

    // Stop-condition tuning.
    private let silenceTimeout: TimeInterval = 2.0
    private let hardCap: TimeInterval = 10.0
    /// The spoken "Where to?" cue plays before the mic opens so the car
    /// mic never transcribes our own prompt back at us.
    private let micStartDelay: TimeInterval = 1.2

    init() {}

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: Entry point

    /// Presents the listening alert and starts transcription. Permission
    /// checks happen in the root template BEFORE calling this.
    func start(interfaceController: CPInterfaceController,
               root: CarPlayNavigationRootTemplate,
               viewModel: DriveViewModel) {
        guard self.interfaceController == nil else { return } // already listening
        self.interfaceController = interfaceController
        self.root = root
        self.viewModel = viewModel

        guard #available(iOS 26.0, *) else {
            // Speedio's CarPlay stack is iOS 26+ only; defensive branch.
            presentFallback(message: "Voice search needs iOS 26 or newer.")
            return
        }

        presentListeningAlert()

        // Small delay so the spoken cue finishes before the car mic opens —
        // otherwise the transcriber hears our own "Where to?" through the
        // car speakers.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(self.micStartDelay * 1_000_000_000))
            guard self.interfaceController != nil else { return } // cancelled meanwhile
            guard #available(iOS 26.0, *) else { return }
            await self.startAudioPipeline()
        }
    }

    // MARK: Listening UI

    private func presentListeningAlert() {
        let stop = CPAlertAction(title: "Stop") { [weak self] _ in
            Task { @MainActor in self?.finalizeTranscript() }
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in self?.cancelListening() }
        }
        let alert = CPAlertTemplate(
            titleVariants: ["Listening…", "Say a destination"],
            actions: [stop, cancel]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        // Spoken cue so the driver knows the mic is live without glancing
        // at the head unit. Routes through the shared navigation announcer
        // so we never own a second synthesizer on CarPlay.
        viewModel?.navigationCoordinator.announceNavigation("Where to?")
    }

    private func presentFallback(message: String) {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                self?.resetState()
            }
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: Audio pipeline

    @available(iOS 26.0, *)
    private func startAudioPipeline() async {
        let session = AVAudioSession.sharedInstance()
        self.audioSession = session

        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            // Car mic first, session default (phone/Bluetooth) as fallback.
            try session.setPreferredInput(CarPlayAudioInput.preferredInput(from: session))
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLogger.shared.log("Voice search: audio session setup failed: \(error.localizedDescription)")
            presentFallback(message: "Microphone unavailable. Try again or use the search keyboard.")
            return
        }

        watchForRouteChanges()
        await runTranscriber()
    }

    /// iOS 26 primary path: SpeechTranscriber + SpeechAnalyzer (on-device).
    @available(iOS 26.0, *)
    private func runTranscriber() async {
        do {
            guard SpeechTranscriber.isAvailable else {
                presentFallback(message: "Voice search isn't supported on this device. Use the search keyboard instead.")
                return
            }
            // Resolve the device language to a supported transcriber locale
            // (accepts a near-equivalent, e.g. en-GB request on an en-US
            // device, rather than failing outright).
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                presentFallback(message: "Voice search isn't available for your language yet. Use the search keyboard instead.")
                return
            }

            let transcriber = try SpeechTranscriber(locale: resolved, preset: .progressiveLiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzerHandle = analyzer

            // On-device model assets are usually preinstalled for the
            // device language; download only when missing.
            let installed = await SpeechTranscriber.installedLocales
            let bcp47 = resolved.identifier(.bcp47)
            if !installed.contains(where: { $0.identifier(.bcp47) == bcp47 }) {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            }

            let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

            // Drain FINAL results into the shared box. Volatile (partial)
            // results are ignored — the flow only searches the completed
            // utterance. The stream ends when the analyzer session finishes
            // (finalize/cancel), which is what unblocks this task.
            let box = finalBox
            resultsTaskDone = false
            resultsTask = Task { @MainActor [weak self] in
                do {
                    for try await result in transcriber.results {
                        if result.isFinal {
                            box.append(result.text.description)
                        }
                    }
                } catch {
                    // Session finished or cancelled — expected on teardown.
                }
                self?.resultsTaskDone = true
            }

            // Audio engine + tap. Buffers are converted to the analyzer's
            // preferred format (the analyzer does NOT convert itself) and
            // yielded through the input stream the analyzer consumes.
            let engine = AVAudioEngine()
            self.audioEngine = engine
            let input = engine.inputNode
            let hardwareFormat = input.outputFormat(forBus: 0)
            let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
            let gate = levelGate
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

            input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
                // Silence-detection input: RMS dB from the hardware buffer.
                gate.note(levelDB: Self.rmsDB(for: buffer), now: CACurrentMediaTime())
                let converted = converter.flatMap { try? Self.convertBuffer(buffer, using: $0, to: targetFormat) }
                // Fall back to the raw buffer if conversion ever fails —
                // same format taps (no resample) convert to themselves.
                let out = converted ?? buffer
                continuation.yield(AnalyzerInput(buffer: out))
            }

            try await analyzer.start(inputSequence: stream)
            try engine.start()

            // Silence clock starts when the mic actually opens.
            levelGate.markStart(now: CACurrentMediaTime())
            startTimers()
        } catch {
            DebugLogger.shared.log("Voice search: SpeechTranscriber failed: \(error.localizedDescription)")
            stopTimers()
            teardownAudio()
            presentFallback(message: "Voice search hit a snag. Try again, or use the search keyboard.")
        }
    }

    // MARK: Completion paths

    /// Stop / silence / hard cap: flush whatever was recognized and hand it
    /// to the search results flow.
    private func finalizeTranscript() {
        guard !isFinalizing else { return }
        isFinalizing = true
        stopTimers()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        // No continuation.finish() here: finalizeAndFinishThroughEndOfInput
        // drains the pending audio through the transcriber so the tail of
        // the utterance still becomes a final result.
        Task { @MainActor in
            if #available(iOS 26.0, *), let analyzer = self.analyzerHandle as? SpeechAnalyzer {
                // Finalize (not cancel) flushes the tail of the utterance so
                // the last words still become a final result.
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            // Wait (bounded) for the results stream to deliver the finals.
            for _ in 0..<20 where !self.resultsTaskDone {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let transcript = self.finalBox.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            self.teardownAudio()

            guard let root = self.root else {
                self.resetState()
                return
            }
            if transcript.isEmpty {
                self.presentFallback(message: "I didn't catch that. Tap the mic and try again.")
                self.resetState()
            } else {
                // The listening alert is dismissed as part of presenting the
                // results list, not before it.
                root.presentVoiceSearchResults(query: transcript)
                self.resetState()
            }
        }
    }

    /// Cancel: discard everything and return to the map.
    private func cancelListening() {
        guard !isFinalizing else { return }
        isFinalizing = true
        stopTimers()
        teardownAudio()
        Task { @MainActor in
            if #available(iOS 26.0, *), let analyzer = self.analyzerHandle as? SpeechAnalyzer {
                try? await analyzer.cancelAndFinishNow()
            }
            self.interfaceController?.dismissTemplate(animated: true, completion: nil)
            self.resetState()
        }
    }

    // MARK: Teardown

    private func resetState() {
        resultsTask?.cancel()
        resultsTask = nil
        analyzerHandle = nil
        audioEngine = nil
        audioSession = nil
        interfaceController = nil
        root = nil
        viewModel = nil
        resultsTaskDone = true
        isFinalizing = false
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    private func teardownAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        if let session = audioSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Stop conditions

    private func startTimers() {
        // Silence: ~2 s without audio above the gate ends the utterance and
        // searches what was heard. Nothing heard at all also lands here
        // (the clock starts when the mic opens), giving the empty-transcript
        // fallback instead of an open mic forever.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let sinceLoud = self.levelGate.secondsSinceLastLoud(now: CACurrentMediaTime())
                if sinceLoud >= self.silenceTimeout {
                    self.finalizeTranscript()
                }
            }
        }
        // Hard cap: 10 s maximum per utterance, period.
        hardCapTimer = Timer.scheduledTimer(withTimeInterval: hardCap, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finalizeTranscript()
            }
        }
    }

    private func stopTimers() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        hardCapTimer?.invalidate()
        hardCapTimer = nil
    }

    // MARK: Buffer helpers

    /// Converts a hardware buffer to the analyzer's preferred format using
    /// the pre-built converter (Apple's SpeechAnalyzer sample pattern).
    /// `nonisolated` so the audio render thread can call it.
    nonisolated private static func convertBuffer(_ buffer: AVAudioPCMBuffer,
                                      using converter: AVAudioConverter,
                                      to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "CarPlayVoiceSearch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate conversion buffer"])
        }
        var fed = false
        let status = converter.convert(to: converted, error: nil) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            throw NSError(domain: "CarPlayVoiceSearch", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed"])
        }
        return converted
    }

    /// RMS level in dBFS for the silence gate. Best-effort: a silent or
    /// non-float buffer reports -160 dB (never triggers the gate).
    /// `nonisolated` so the audio render thread can call it.
    nonisolated private static func rmsDB(for buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channels {
            let ptr = data[channel]
            for frame in 0..<frames {
                let v = ptr[frame]
                sum += v * v
            }
        }
        let rms = (sum / Float(frames * channels)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    // MARK: Route changes

    /// If the car (or Bluetooth kit) disconnects mid-listen, re-pick the
    /// preferred input so the remaining audio doesn't drop.
    private func watchForRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let session = self.audioSession else { return }
                try? session.setPreferredInput(CarPlayAudioInput.preferredInput(from: session))
            }
        }
    }
}

// MARK: - CarPlayAudioInput

/// Microphone selection policy: prefer the CAR's mic, fall back to whatever
/// the session default resolves to (phone mic / Bluetooth kit) when no car
/// microphone is exposed on the current audio route.
enum CarPlayAudioInput {

    /// Returns the session input that should be used for dictation: the
    /// first `.carAudio` input when one is present, otherwise `nil` (which
    /// leaves the session's default input unchanged).
    static func preferredInput(from session: AVAudioSession) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        // Car head units expose their mic as a `.carAudio` port when the
        // vehicle supports it. Prefer it 100% of the time it exists.
        if let carMic = inputs.first(where: { $0.portType == .carAudio }) {
            return carMic
        }
        // No car mic: keep the session default (phone mic or a connected
        // Bluetooth car kit).
        return nil
    }
}

// MARK: - Thread-safe helpers
//
// The audio tap runs on the audio render thread (nonisolated) while the
// controller is @MainActor, so the state shared in between must be its own
// tiny synchronized types.

/// Accumulates final transcript fragments from the transcriber's result
/// sequence for the controller to collect on stop.
final class FinalTranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [String] = []

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        fragments.append(text)
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return fragments.joined(separator: " ")
    }
}

/// Tracks the last moment audio exceeded the speech gate so the MainActor
/// silence timer can decide the utterance ended.
final class AudioLevelGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gateDB: Float
    private var lastLoudTimestamp: TimeInterval = 0

    init(gateDB: Float) {
        self.gateDB = gateDB
    }

    func markStart(now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        lastLoudTimestamp = now
    }

    func note(levelDB: Float, now: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if levelDB > gateDB {
            lastLoudTimestamp = now
        }
    }

    func secondsSinceLastLoud(now: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastLoudTimestamp > 0 else { return .infinity }
        return now - lastLoudTimestamp
    }
}
