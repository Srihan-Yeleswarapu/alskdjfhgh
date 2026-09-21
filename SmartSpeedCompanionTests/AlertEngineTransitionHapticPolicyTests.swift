import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Transition haptics: contextual patterns fired on status boundaries
/// independent of the user's chosen alert style.
///   .over → .safe/.warning : relief ("you slowed down")
///   .safe → .warning       : near-limit anticipation, fires ONCE
/// Both require haptics enabled. Verified behaviorally where the state is
/// observable (published flags, counters) and by source contract where the
/// effect is hardware-bound (CHHapticEngine calls).
@MainActor
final class AlertEngineTransitionHapticPolicyTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var alertEngine: AlertEngine!
    private var speedEngine: SpeedEngine!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set(false, forKey: "audioAlertsEnabled")
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        UserDefaults.standard.set(5, forKey: "userBuffer")
        speedEngine = SpeedEngine(locationManager: LocationManager())
        alertEngine = AlertEngine(speedEngine: speedEngine)
    }

    override func tearDown() {
        alertEngine = nil
        speedEngine = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Transition source contracts

    func testReliefHapticFiresOnOverToSafe() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        let section = try section(in: source, anchor: "Transition Haptics")
        XCTAssertTrue(section.contains("previousStatus == .over"),
                      "Relief path must compare against the previous .over status")
        XCTAssertTrue(section.contains("playSuccessHaptic"),
                      "Relief transition must map to the success haptic")
    }

    func testNearHapticFiresOnceOnSafeToWarning() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        let section = try section(in: source, anchor: "Anticipatory haptic")
        XCTAssertTrue(section.contains("previousStatus == .safe && status == .warning"),
                      "Near-limit haptic must fire only on the safe→warning edge")
        XCTAssertTrue(section.contains("playNearHaptic"))
    }

    func testTransitionHapticsRespectEnableToggle() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        let section = try section(in: source, anchor: "Transition Haptics")
        XCTAssertTrue(section.contains("isHapticAlertsEnabled"),
                      "Transition haptics must be gated on the haptics toggle")
    }

    func testUnknownLimitResetsTransitionBaseline() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        // The guard for unresolved limits resets previousStatus = .safe so
        // a limit-refresh wobble can't fire a bogus relief haptic.
        XCTAssertTrue(source.contains("previousStatus = .safe"),
                      "Unknown-limit guard must reset the transition baseline")
    }

    // MARK: - Behavioral: previousStatus bookkeeping via episode counts

    /// The haptic engine is hardware-bound, but its *decision* inputs are
    /// the published SpeedEngine state. This walks the real transitions and
    /// asserts the alert state machine consumes them without error and the
    /// counters behave — the observable half of the contract.
    func testFullTransitionWalkKeepsCountersConsistent() {
        // safe → warning
        speedEngine.speed = 54.5
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(speedEngine.status, .warning)
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0, "warning is not an episode")

        // warning → over (episode starts)
        speedEngine.speed = 56
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1)

        // over → safe (relief; episode ends)
        speedEngine.speed = 40
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0)

        // safe → warning again: near-haptic edge may fire a second time
        // by design (it is edge-triggered per transition, not per drive).
        speedEngine.speed = 54.5
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(speedEngine.status, .warning)
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0)
    }

    /// rapid over → warning → over must not double-start monitoring:
    /// the second .over entry finds the timer dead (stopMonitoringState
    /// ran on the intermediate warning) and starts a FRESH episode.
    func testOverWarningOverCycleRestartsCleanEpisode() {
        speedEngine.speed = 60
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1)

        speedEngine.speed = 54.5
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0)

        speedEngine.speed = 60
        speedEngine.applyResolvedLimit(50)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1,
                       "Re-entry after teardown must be a fresh episode starting at 1")
    }

    // MARK: - HapticStyle catalog integrity (settings usability)

    func testEveryHapticStyleHasDisplayName() {
        for style in HapticStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty, "\(style.rawValue) has no display name")
        }
        XCTAssertEqual(HapticStyle.allCases.count, 11, "Style catalog changed — Settings picker must be revisited")
    }

    func testStyleRawValueRoundTrip() {
        for style in HapticStyle.allCases {
            XCTAssertEqual(HapticStyle(rawValue: style.rawValue), style)
        }
    }

    func testCustomFallbackPatternIsWellFormed() {
        let fallback = HapticTapEvent.fallback
        XCTAssertEqual(fallback.count, 2)
        for (idx, tap) in fallback.enumerated() {
            if idx > 0 {
                XCTAssertGreaterThan(tap.timeOffset, fallback[idx - 1].timeOffset,
                                     "Fallback taps must be chronologically ordered")
            }
            XCTAssertTrue((0...1).contains(tap.intensity))
        }
    }

    func testTapEventClampsInvalidInput() {
        let negative = HapticTapEvent(timeOffset: -3, intensity: 5)
        XCTAssertEqual(negative.timeOffset, 0)
        XCTAssertEqual(negative.intensity, 1.0)

        let deep = HapticTapEvent(timeOffset: 10, intensity: -1)
        XCTAssertEqual(deep.intensity, 0.0)
    }

    func testCustomPatternPersistenceRoundTrip() {
        let pattern = [HapticTapEvent(timeOffset: 0, intensity: 1),
                       HapticTapEvent(timeOffset: 0.2, intensity: 0.5),
                       HapticTapEvent(timeOffset: 0.5, intensity: 0.8)]
        HapticAlertManager.shared.customPatternData = encodePattern(pattern)
        let decoded = decodePattern(HapticAlertManager.shared.customPatternData)
        XCTAssertEqual(decoded, pattern)
        HapticAlertManager.shared.customPatternData = Data()
    }

    // MARK: - Helpers

    private func encodePattern(_ taps: [HapticTapEvent]) -> Data {
        let encoder = JSONEncoder()
        return (try? encoder.encode(taps)) ?? Data()
    }

    private func decodePattern(_ data: Data) -> [HapticTapEvent] {
        (try? JSONDecoder().decode([HapticTapEvent].self, from: data)) ?? []
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
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }
}
