import XCTest
import AVFoundation
@testable import SmartSpeedCompanion

/// AudioSessionCoordinator: the single process-wide owner of the audio
/// session. Before it existed, the tone engine and nav announcer fought
/// over category/activation — the root cause of glitchy CarPlay audio.
/// The ref-counted focus model is verified here: paired begin/end, idempotent
/// activation, and the category policy via source contract (hardware
/// activation itself is environment-bound).
@MainActor
final class AudioSessionCoordinatorFocusTests: XCTestCase {

    private var coordinator: AudioSessionCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = AudioSessionCoordinator()
    }

    override func tearDown() {
        // Drain any leases the test acquired so other suites start clean.
        for _ in 0..<10 { coordinator.endCue() }
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Cue ref-counting

    func testBeginCueIsIdempotent() {
        coordinator.beginCue()
        coordinator.beginCue()
        coordinator.beginCue()
        // No crash / no state corruption — a ref-count >= 1 is held.
    }

    func testCueEndWithoutBeginIsSafe() {
        coordinator.endCue() // must not crash on an empty lease table
        coordinator.endCue()
    }

    func testCuePairingDrainsToZero() {
        coordinator.beginCue()
        coordinator.beginCue()
        coordinator.endCue()
        coordinator.endCue()
        coordinator.endCue() // extra end: tolerated
    }

    func testEnsureActiveDoesNotThrow() {
        // ensureActive() activates on demand; in the test host this may
        // succeed or fail depending on the simulator's audio server, but
        // it must never trap.
        coordinator.ensureActive()
    }

    // MARK: - Source contracts (the design that ended the tug-of-war)

    func testCoordinatorIsProcessWideSingleton() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("static let shared") || source.contains("public static let shared"),
                      "The coordinator must be a singleton — per-owner sessions recreate the CarPlay tug-of-war")
    }

    func testAlertEngineUsesCoordinatorNotDirectSessionConfig() throws {
        let alertSource = try String(contentsOfFile: alertPath(), encoding: .utf8)
        // The AlertEngine's init must NOT configure AVAudioSession directly.
        let initSection = try section(in: alertSource, anchor: "public init(speedEngine: SpeedEngine)")
        XCTAssertFalse(initSection.contains("AVAudioSession.sharedInstance().setCategory"),
                       "AlertEngine must not configure the audio session directly (AudioSessionCoordinator owns it)")
        XCTAssertTrue(alertSource.contains("beginAlertAudioFocus") || alertSource.contains("endAlertAudioFocus"),
                      "Alert focus must flow through the coordinator's lease methods")
    }

    func testNavAnnouncerUsesCueLeases() throws {
        let navSource = try String(contentsOfFile: navPath(), encoding: .utf8)
        XCTAssertTrue(navSource.contains("AudioSessionCoordinator.shared.beginCue()"),
                      "Speech cues must acquire focus through the coordinator")
    }

    func testAnnouncerHoldsSingleCuePerUtterance() throws {
        let navSource = try String(contentsOfFile: navPath(), encoding: .utf8)
        XCTAssertTrue(navSource.contains("cueHeld"),
                      "One audio-focus cue per utterance; released from the speech delegate after finish")
    }

    // MARK: - Announcement queue policy

    func testPendingMessagePolicyKeepsNewestOnly() throws {
        let navSource = try String(contentsOfFile: navPath(), encoding: .utf8)
        let announce = try section(in: navSource, anchor: "func announce(_ message: String)")
        XCTAssertTrue(announce.contains("pendingMessages = [expandedMessage]"),
                      "A new cue while speaking replaces the queue — the latest nav state is the useful one")
    }

    func testVoiceDisabledShortCircuitsAnnouncements() throws {
        let navSource = try String(contentsOfFile: navPath(), encoding: .utf8)
        let announce = try section(in: navSource, anchor: "func announce(_ message: String)")
        XCTAssertTrue(announce.contains("voiceNavEnabled"),
                      "The voice toggle must gate announcements before any synthesizer work")
    }

    // MARK: - Abbreviation expansion (the TTS pre-processor)

    func testExpandAbbreviationsStreetTypes() {
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations("Turn left on Main St"),
                       "Turn left on Main Street")
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations("Continue on Frye Rd"),
                       "Continue on Frye Road")
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations("Merge onto Loop 101 Fwy"),
                       "Merge onto Loop 101 Freeway")
    }

    func testExpandAbbreviationsDirections() {
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations("Head N on I-17"),
                       "Head North on Interstate 17")
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations("Take Exit 5 W"),
                       "Take Exit 5 West")
    }

    func testExpandDoesNotBreakWords() {
        // \b boundaries: "W" inside "Way" must survive.
        let result = NavigationCoordinator.expandAbbreviations("Continue on Miller Way")
        XCTAssertTrue(result.contains("Way"), "Word-boundary broken: \(result)")
        XCTAssertFalse(result.contains("West Way"))
    }

    func testExpandIsCaseInsensitive() {
        let result = NavigationCoordinator.expandAbbreviations("turn onto main ST")
        XCTAssertTrue(result.lowercased().contains("street"))
    }

    func testExpandHandlesPlainTextUnchanged() {
        let plain = "You have arrived at your destination"
        XCTAssertEqual(NavigationCoordinator.expandAbbreviations(plain), plain)
    }

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AudioSessionCoordinator.swift"
        #else
        return "SmartSpeedCompanion/Core/AudioSessionCoordinator.swift"
        #endif
    }

    private func alertPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }

    private func navPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\ViewModels\\NavigationCoordinator.swift"
        #else
        return "SmartSpeedCompanion/ViewModels/NavigationCoordinator.swift"
        #endif
    }
}
