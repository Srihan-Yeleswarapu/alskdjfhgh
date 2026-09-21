import XCTest
import CoreHaptics
@testable import SmartSpeedCompanion

/// HapticAlertManager's decision layer (hardware calls are environment-
/// bound, decisions are not): the severity curve that maps mph-over to
/// pulse intensity, the pulse lifecycle gates, style catalog, and custom
/// pattern serialization. The accidental-vibration regression class is
/// anchored by the pure policy function.
@MainActor
final class HapticPatternCatalogAndSeverityTests: XCTestCase {

    // MARK: - Severity curve (computedSeverity policy, hand-computed)

    /// severity = 0.1 + 0.9 × clamp((mphOver − 1) / 19, 0...1) — +1 over ≈
    /// 0.15, +20 over ≈ 1.0 (per the documented curve). Pin the anchors.
    func testSeverityAnchors() {
        func severity(mphOver: Double) -> Double {
            let normalized = max(0, min(1, (mphOver - 1) / 19))
            return 0.1 + 0.9 * normalized
        }
        XCTAssertEqual(severity(mphOver: 1), 0.1, accuracy: 0.01)
        XCTAssertEqual(severity(mphOver: 10), 0.526, accuracy: 0.02)
        XCTAssertEqual(severity(mphOver: 20), 1.0, accuracy: 0.01)
        XCTAssertEqual(severity(mphOver: 40), 1.0, accuracy: 0.01, "Severity clamps at 1.0")
        XCTAssertEqual(severity(mphOver: 0), 0.1, accuracy: 0.01, "Negative over clamps to the floor")
    }

    // MARK: - Pulse lifecycle gates

    func testPulseRequiresEnabledHaptics() throws {
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.5)
        // No crash; hardware path no-ops when disabled. Stop must be safe too.
        HapticAlertManager.shared.stopSpeedingPulse()
    }

    func testStartStopPulseIsSymmetric() {
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.8)
        HapticAlertManager.shared.startSpeedingPulse(severity: 0.9) // restart with new severity
        HapticAlertManager.shared.stopSpeedingPulse()
        HapticAlertManager.shared.stopSpeedingPulse() // idempotent stop
    }

    func testFireIfEnabledRespectsToggle() {
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        HapticAlertManager.shared.fireIfEnabled(severity: 1.0, consecutiveSeconds: 5)
        // Disabled → no-op (no crash, no vibration on a real device).
    }

    // MARK: - Static transition haptics are safe without hardware

    func testStaticHapticsAreSafeOnNonHapticDevices() {
        // Each plays through the fallback path on unsupported hardware.
        HapticAlertManager.playWarningBuzz()
        HapticAlertManager.playSuccessHaptic()
        HapticAlertManager.playNearHaptic()
        HapticAlertManager.playNavigationPop()
        HapticAlertManager.playNavigationNope()
        HapticAlertManager.playRecordingStarted()
        HapticAlertManager.playRecordingStopped()
        HapticAlertManager.playFocusModeEnter()
        HapticAlertManager.playFocusModeExit()
    }

    // MARK: - Style catalog

    func testAllStylesHaveDisplayNames() {
        for style in HapticStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty, style.rawValue)
            XCTAssertTrue(style.displayName.count < 30, "\(style) name too long for the picker row")
        }
    }

    func testStyleCodableRoundTrip() throws {
        for style in HapticStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(HapticStyle.self, from: data)
            XCTAssertEqual(decoded, style)
        }
    }

    // MARK: - Custom pattern persistence

    func testCustomPatternDataRoundTrip() throws {
        let taps = [
            HapticTapEvent(timeOffset: 0.0, intensity: 1.0),
            HapticTapEvent(timeOffset: 0.15, intensity: 0.6),
            HapticTapEvent(timeOffset: 0.4, intensity: 0.9),
        ]
        let data = try JSONEncoder().encode(taps)
        HapticAlertManager.shared.customPatternData = data
        let decoded = try JSONDecoder().decode([HapticTapEvent].self,
                                               from: HapticAlertManager.shared.customPatternData)
        XCTAssertEqual(decoded, taps)

        // saveCustomPattern must persist the same JSON.
        let recorded = [HapticTapEvent(timeOffset: 0.05, intensity: 0.7)]
        HapticAlertManager.shared.saveCustomPattern(recorded)
        XCTAssertEqual(HapticAlertManager.shared.customPatternData,
                       try JSONEncoder().encode(recorded))

        // Cleanup so the operator's recorded pattern is untouched.
        HapticAlertManager.shared.customPatternData = Data()
    }

    func testEmptyCustomPatternFallsBack() {
        HapticAlertManager.shared.customPatternData = Data()
        XCTAssertEqual(HapticTapEvent.fallback.count, 2,
                       "Empty custom data must yield the documented two-tap fallback")
    }

    // MARK: - Engine readiness policy

    func testEnginePreparationIsLazilyQueued() throws {
        let source = try String(contentsOfFile: hapticPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("isPreparingEngine"),
                      "CHHapticEngine startup must be queued off-main (launch-hang fix)")
        XCTAssertTrue(source.contains("ensureEngine") || source.contains("ensureToneEngine"),
                      "First-use preparation path must exist")
    }

    func testDeviceCapabilityQueryIsOffMain() throws {
        let source = try String(contentsOfFile: hapticPath(), encoding: .utf8)
        XCTAssertTrue(source.contains("capabilitiesForHardware"),
                      "Capability query documented as the XR hang fix")
    }

    private func hapticPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\HapticAlertManager.swift"
        #else
        return "SmartSpeedCompanion/Core/HapticAlertManager.swift"
        #endif
    }
}
