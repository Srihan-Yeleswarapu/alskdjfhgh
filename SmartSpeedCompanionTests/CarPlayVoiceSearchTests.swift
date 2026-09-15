import XCTest
@testable import SmartSpeedCompanion

/// Regression tests for the "Ask To Siri" CarPlay voice destination search
/// (mic map button -> spoken destination -> results list -> trip preview).
///
/// The flow must reuse the keyboard's submitted-results path (the driver
/// always picks the destination — never auto-navigation), prefer the car's
/// microphone, and degrade to a visible/spoken fallback when speech isn't
/// available instead of leaving a broken mic on screen.
final class CarPlayVoiceSearchTests: XCTestCase {

    // MARK: - Configuration

    func testUsageDescriptionsDeclaredForMicAndSpeech() throws {
        let project = try String(contentsOfFile: projectYMLPath(), encoding: .utf8)
        XCTAssertTrue(
            project.contains("NSMicrophoneUsageDescription: \"Speedio uses the microphone so you can speak a destination on CarPlay instead of typing it.\""),
            "CarPlay voice search needs the mic usage description or iOS blocks recording with no explanation."
        )
        XCTAssertTrue(
            project.contains("NSSpeechRecognitionUsageDescription: \"Your speech is transcribed on-device to find the destination you say.\""),
            "Speech recognition needs its usage description; the transcription is on-device only."
        )
    }

    func testEntitlementsUntouchedByVoiceSearch() throws {
        let entitlements = try String(contentsOfFile: entitlementsPath(), encoding: .utf8)
        XCTAssertFalse(
            entitlements.lowercased().contains("microphone"),
            "Mic + speech need only usage descriptions; the entitlements file must stay untouched."
        )
    }

    // MARK: - CarPlay-only wiring

    func testMicButtonIsCarPlayOnlyAndUsesExistingUIStyle() throws {
        let root = try String(contentsOfFile: carPlayRootTemplateSourcePath(), encoding: .utf8)
        XCTAssertTrue(root.contains("voiceSearchButton = CPMapButton"), "The mic must be a CPMapButton on the CarPlay map template.")
        XCTAssertTrue(root.contains("systemName: \"mic.fill\""), "The button must use the mic glyph.")
        // Settings are phone-only by design; the mic entry point must not
        // leak into any phone view.
        let phoneViews = try phoneViewSources()
        for (path, source) in phoneViews {
            XCTAssertFalse(
                source.contains("voiceSearchButton") || source.contains("presentVoiceSearch"),
                "\(path) must not reference the CarPlay voice search entry point — it is CarPlay-only."
            )
        }
    }

    func testPermissionFlowCoversMicAndSpeechWithFallbackAlert() throws {
        let root = try String(contentsOfFile: carPlayRootTemplateSourcePath(), encoding: .utf8)
        let permBody = try sourceSection(in: root, anchor: "private func presentVoiceSearch()")
        XCTAssertTrue(permBody.contains("AVAudioApplication.shared.recordPermission"), "Mic permission must be checked via the modern AVAudioApplication API.")
        XCTAssertTrue(permBody.contains("AVAudioApplication.requestRecordPermission"), "First-run must request mic permission.")
        XCTAssertTrue(permBody.contains("SFSpeechRecognizer.requestAuthorization"), "Speech authorization must be requested separately from mic permission.")
        XCTAssertTrue(permBody.contains("presentVoicePermissionAlert"), "Denied permission must surface the Settings-pointing alert.")
        XCTAssertTrue(root.contains("Voice search needs microphone access"), "The denial alert must tell the driver where to enable the mic.")
    }

    // MARK: - Voice flow behavior

    func testVoiceResultsReuseSubmittedResultsListNeverAutoNavigate() throws {
        let root = try String(contentsOfFile: carPlayRootTemplateSourcePath(), encoding: .utf8)
        let handoffBody = try sourceSection(in: root, anchor: "func presentVoiceSearchResults(query: String)")
        // Same surface the keyboard Search button lands on.
        XCTAssertTrue(handoffBody.contains("presentSubmittedSearchResults"), "The transcript must flow into the same results list the keyboard Search button uses.")
        // Generation guard: a late response from a previous search must not
        // overwrite the driver's newer query.
        XCTAssertTrue(handoffBody.contains("searchGeneration &+= 1"), "The handoff must bump the search generation so stale responses are dropped.")
        // No auto-navigation anywhere in the handoff.
        XCTAssertFalse(handoffBody.contains("startNavigation"), "Voice search must never auto-start navigation; the driver picks the destination.")
        XCTAssertFalse(handoffBody.contains("handleCarPlayStartedTrip"), "Voice search must never trigger a trip start.")
    }

    func testVoiceControllerSearchesTranscriptNotViewModelPublishedResults() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        // The phone-side searchResults array stays untouched while driving.
        XCTAssertTrue(controller.contains("root.presentVoiceSearchResults(query:"), "The transcript must be handed to the CarPlay root template, not the phone ViewModel search state.")
        XCTAssertFalse(
            controller.contains("publishResults"),
            "The voice flow must not touch the phone-side published searchResults at all."
        )
    }

    func testCarMicPreferredWithDefaultFallback() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        XCTAssertTrue(controller.contains("enum CarPlayAudioInput"), "The mic-selection policy must be its own helper type.")
        let inputBody = try sourceSection(in: controller, anchor: "enum CarPlayAudioInput")
        XCTAssertTrue(inputBody.contains(".carAudio"), "The car's microphone port must be preferred when present.")
        XCTAssertTrue(inputBody.contains("inputs.first(where: { $0.portType == .carAudio })"), "Selection must scan availableInputs for the car mic.")
        // Fallback: nil leaves the session default (phone mic / Bluetooth).
        XCTAssertTrue(inputBody.contains("return nil"), "No car mic must fall back to the session default input.")
        let startBody = try sourceSection(in: controller, anchor: "private func startAudioPipeline() async")
        XCTAssertTrue(startBody.contains("CarPlayAudioInput.preferredInput(from:"), "The audio pipeline must apply the car-mic-first policy.")
    }

    func testSpeechUsesOnDeviceSpeechTranscriberWithFallbacks() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        XCTAssertTrue(controller.contains("SpeechTranscriber(locale:"), "iOS 26 path must use the on-device SpeechTranscriber API.")
        XCTAssertTrue(controller.contains(".progressiveTranscription"), "Live utterances should use the progressive preset.")
        XCTAssertTrue(controller.contains("SpeechTranscriber.isAvailable"), "Device capability must be checked before starting.")
        XCTAssertTrue(controller.contains("supportedLocale(equivalentTo:"), "Locale resolution must accept near-equivalents instead of failing.")
        XCTAssertTrue(controller.contains("AssetInventory.assetInstallationRequest"), "Missing on-device model assets must be downloaded on demand.")
        // Clean degradation paths (visible alert, never a dead mic).
        XCTAssertTrue(controller.contains("presentFallback(message:"), "Every failure path must surface a visible message.")
        XCTAssertTrue(controller.contains("I didn't catch that"), "An empty transcript must land on the try-again fallback.")
    }

    func testListeningAlertHasStopAndCancelAndSpokenCue() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        let alertBody = try sourceSection(in: controller, anchor: "private func presentListeningAlert()")
        XCTAssertTrue(alertBody.contains("CPAlertTemplate"), "Listening must be presented as a CarPlay alert template.")
        XCTAssertTrue(alertBody.contains("\"Stop\""), "The driver must be able to stop early.")
        XCTAssertTrue(alertBody.contains("style: .cancel"), "Cancel must be visually distinct from Stop.")
        XCTAssertTrue(alertBody.contains("announceNavigation"), "A spoken cue must tell the driver the mic is live without a glance.")
    }

    func testStopConditionsSilenceAndHardCap() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        let timersBody = try sourceSection(in: controller, anchor: "private func startTimers()")
        XCTAssertTrue(timersBody.contains("silenceTimeout"), "Silence must end the utterance.")
        XCTAssertTrue(timersBody.contains("hardCap"), "A hard cap must bound every listening session.")
        // Level gate is a synchronized type shared with the audio tap.
        XCTAssertTrue(controller.contains("final class AudioLevelGate"), "Silence detection must share level state with the nonisolated audio tap.")
    }

    func testTeardownDeactivatesAudioSessionAndNotifiesOthers() throws {
        let controller = try String(contentsOfFile: voiceControllerSourcePath(), encoding: .utf8)
        let teardownBody = try sourceSection(in: controller, anchor: "private func teardownAudio()")
        XCTAssertTrue(teardownBody.contains("removeTap(onBus: 0)"), "The input tap must be removed or the audio engine leaks.")
        XCTAssertTrue(teardownBody.contains("setActive(false, options: .notifyOthersOnDeactivation)"), "Deactivation must notify others so navigation TTS recovers cleanly.")
        XCTAssertTrue(controller.contains("cancelAndFinishNow"), "Cancel must end the analyzer session so the results stream terminates.")
    }

    func testStaleResponseGuardAndSingleVoiceController() throws {
        let root = try String(contentsOfFile: carPlayRootTemplateSourcePath(), encoding: .utf8)
        XCTAssertTrue(root.contains("private var voiceSearchController: CarPlayVoiceSearchController?"), "One controller instance guards double-taps while the listening alert is up.")
        let beginBody = try sourceSection(in: root, anchor: "private func presentVoiceSearch()")
        XCTAssertTrue(beginBody.contains("guard voiceSearchController == nil else { return }"), "A second mic tap during listening must be ignored.")
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n    }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func projectYMLPath() -> String {
        #if os(Windows)
        return "project.yml"
        #else
        return "project.yml"
        #endif
    }

    private func entitlementsPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Resources\\Entitlements\\SmartSpeedCompanion.entitlements"
        #else
        return "SmartSpeedCompanion/Resources/Entitlements/SmartSpeedCompanion.entitlements"
        #endif
    }

    private func voiceControllerSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayVoiceSearchController.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayVoiceSearchController.swift"
        #endif
    }

    private func carPlayRootTemplateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationRootTemplate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift"
        #endif
    }

    /// Phone-side views that must NOT reference the CarPlay-only mic entry.
    private func phoneViewSources() throws -> [(path: String, source: String)] {
        let paths = [
            "SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift",
            "SmartSpeedCompanion/Views/Drive/LiveMapView.swift"
        ]
        return try paths.map { p in
            let source = try String(contentsOfFile: p, encoding: .utf8)
            return (p, source)
        }
    }
}
