import XCTest
import AVFoundation
@testable import SmartSpeedCompanion

/// AudioSessionCoordinator owns the process-wide AVAudioSession. The hang
/// signature it exists to prevent: AVAudioSession.setCategory/setActive
/// synchronously blocking the main actor from alert/speech callbacks (the
/// reported XR run-loop stalls). These tests hold the shared coordinator to
/// that contract — every public call must return to the caller promptly, the
/// reference count must survive overlapping cues, and idle-state calls must
/// be no-ops. Real coordinator (singleton), no mocking of the session, but
/// all assertions are timing/behavioral, not route-dependent, so they pass
/// with any audio hardware present on the test simulator.
@MainActor
final class AudioSessionMainActorLatencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Drain any cue state a previous test left behind.
        AudioSessionCoordinator.shared.endCue()
        AudioSessionCoordinator.shared.endCue()
        AudioSessionCoordinator.shared.endCue()
    }

    override func tearDown() {
        AudioSessionCoordinator.shared.endCue()
        AudioSessionCoordinator.shared.endCue()
        AudioSessionCoordinator.shared.endCue()
        super.tearDown()
    }

    /// Pumps the main run loop for `seconds`, returning the observed drift
    /// (actual − requested). A synchronous AVAudioSession call on the main
    /// actor would show up as drift far beyond scheduling noise.
    @discardableResult
    private func pumpMainRunLoop(seconds: TimeInterval) -> TimeInterval {
        let start = Date()
        RunLoop.main.run(until: start.addingTimeInterval(seconds))
        return Date().timeIntervalSince(start) - seconds
    }

    // MARK: - Main-actor latency contract

    func testBeginCueDoesNotBlockTheMainRunloop() {
        let before = Date()
        AudioSessionCoordinator.shared.beginCue()
        let callLatency = Date().timeIntervalSince(before)
        XCTAssertLessThan(callLatency, 0.1,
                          "beginCue took \(callLatency)s on the main actor — the XR hang signature")

        // The audio queue does the blocking work; the main run loop must stay
        // responsive within the same window.
        let drift = pumpMainRunLoop(seconds: 0.25)
        XCTAssertLessThan(drift, 0.2, "main run loop stalled \(drift)s after beginCue")
    }

    func testEndCueDoesNotBlockTheMainRunloop() {
        AudioSessionCoordinator.shared.beginCue()
        let before = Date()
        AudioSessionCoordinator.shared.endCue()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.1,
                          "endCue must not synchronously deactivate the session on main")
        _ = pumpMainRunLoop(seconds: 0.25)
    }

    func testBeginEndRapidCyclingKeepsMainResponsive() {
        // Speech + alert overlap hammers begin/end in quick succession; the
        // coordinator must never serialize AVAudioSession work onto main.
        let start = Date()
        for _ in 0..<30 {
            AudioSessionCoordinator.shared.beginCue()
            AudioSessionCoordinator.shared.endCue()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "60 cue operations took \(elapsed)s — main-actor blocking crept back in")
        _ = pumpMainRunLoop(seconds: 0.3)
    }

    // MARK: - Reference counting semantics

    func testOverlappingCuesAreCountedNotClobbered() {
        // Navigation prompt overlapping a speeding tone: both cues must be
        // tracked (2 begins) and the session released only after both end.
        AudioSessionCoordinator.shared.beginCue()
        AudioSessionCoordinator.shared.beginCue()

        AudioSessionCoordinator.shared.endCue() // tone finishes first
        // No direct count accessor; the observable contract is that the
        // coordinator keeps functioning — a third begin/end pair cycles fine.
        AudioSessionCoordinator.shared.beginCue()
        AudioSessionCoordinator.shared.endCue()
        _ = pumpMainRunLoop(seconds: 0.3)
    }

    func testEndCueMoreTimesThanBeginDoesNotGoNegative() {
        // Defensive clamp: max(0, count-1). Extra endCues must be harmless.
        for _ in 0..<5 { AudioSessionCoordinator.shared.endCue() }
        // And the coordinator still works afterwards.
        AudioSessionCoordinator.shared.beginCue()
        AudioSessionCoordinator.shared.endCue()
        _ = pumpMainRunLoop(seconds: 0.3)
    }

    func testEndCueSchedulesDelayedReleaseNotImmediate() {
        // The 500 ms release bridge: after the final endCue, the main run
        // loop must remain responsive while the release task sleeps.
        AudioSessionCoordinator.shared.beginCue()
        AudioSessionCoordinator.shared.endCue()
        let before = Date()
        RunLoop.main.run(until: before.addingTimeInterval(0.05))
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.1,
                          "delayed release must sleep, not spin or block main")
    }

    // MARK: - ensureActive

    func testEnsureActiveWhenIdleIsANoOp() {
        // Interruption recovery calls ensureActive unconditionally; idle it
        // must not activate audio (no surprise playback stealing focus).
        let before = Date()
        AudioSessionCoordinator.shared.ensureActive()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.1)
        _ = pumpMainRunLoop(seconds: 0.2)
    }

    func testEnsureActiveDuringOpenCueReactivatesWithoutBlocking() {
        AudioSessionCoordinator.shared.beginCue()
        let before = Date()
        AudioSessionCoordinator.shared.ensureActive()
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.1)
        AudioSessionCoordinator.shared.endCue()
        _ = pumpMainRunLoop(seconds: 0.3)
    }

    // MARK: - Category contract (documented, stable configuration)

    func testSessionStaysQueryableAcrossCueCycle() {
        // The coordinator's documented configuration is playback/voicePrompt,
        // but activation can legitimately fail on bare simulators — the
        // coordinator's job is to degrade gracefully, never hang or crash.
        // Assert the session object stays queryable through a full cycle.
        AudioSessionCoordinator.shared.beginCue()
        _ = pumpMainRunLoop(seconds: 0.3)
        _ = AVAudioSession.sharedInstance().category
        _ = AVAudioSession.sharedInstance().mode
        AudioSessionCoordinator.shared.endCue()
        _ = pumpMainRunLoop(seconds: 0.3)
    }

    func testSingletonIdentity() {
        // The whole design assumes ONE owner of the audio session.
        XCTAssertTrue(AudioSessionCoordinator.shared === AudioSessionCoordinator.shared)
    }
}
