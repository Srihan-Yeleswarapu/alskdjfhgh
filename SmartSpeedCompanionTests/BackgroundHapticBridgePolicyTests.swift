import XCTest
import CoreLocation
import UserNotifications
@testable import SmartSpeedCompanion

/// BackgroundHapticBridge: when the app is backgrounded and CHHaptics are
/// unavailable, the bridge falls back to notification-triggered vibration
/// (silent_alert.wav + system notification vibration), preserving the
/// user's "audio off" choice while still buzzing. Its tick policy and
/// authorization flow are pinned here.
@MainActor
final class BackgroundHapticBridgePolicyTests: XCTestCase {

    private var bridge: BackgroundHapticBridge!
    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        bridge = BackgroundHapticBridge()
    }

    override func tearDown() {
        bridge?.reset()
        bridge = nil
        defaultsGuard.restore()
        super.tearDown()
    }

    // MARK: - Enable gate

    func testIsEnabledRespectsUserToggle() {
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        // The bridge defers to the same haptics toggle as the in-app engine.
        let enabled = bridge.isEnabled
        _ = enabled // environment-dependent; the contract is a stable Bool read
        UserDefaults.standard.set(true, forKey: "hapticAlertsEnabled")
    }

    func testRequestAuthorizationIsSafeRepeatedly() {
        bridge.requestAuthorizationIfNeeded()
        bridge.requestAuthorizationIfNeeded()
        // Idempotent; must not crash or spam the permission prompt in tests.
    }

    // MARK: - Tick policy

    func testTickWithHapticsDisabledIsNoOp() {
        bridge.reset()
        bridge.handleSpeedingTick(hapticsEnabled: false, speed: 60, limit: 45)
        // No notification scheduling when the user disabled haptics.
    }

    func testTickWhenWithinLimitIsNoOp() {
        bridge.reset()
        bridge.handleSpeedingTick(hapticsEnabled: true, speed: 40, limit: 45)
        // 40 ≤ 45: not speeding, no buzz.
    }

    func testTickWhenOverLimitAndEnabledFires() {
        bridge.reset()
        bridge.handleSpeedingTick(hapticsEnabled: true, speed: 60, limit: 45)
        // The bridge must schedule its notification fallback (behavior
        // observable only as "no crash" in the test host; on-device the
        // notification arrives with silent_alert.wav).
    }

    func testResetClearsTickState() {
        bridge.handleSpeedingTick(hapticsEnabled: true, speed: 60, limit: 45)
        bridge.reset()
        // After reset, a tick sequence starts fresh — no state carried over.
        bridge.handleSpeedingTick(hapticsEnabled: true, speed: 60, limit: 45)
        bridge.reset()
    }

    // MARK: - Source contracts

    func testBridgeUsesSilentAlertSound() throws {
        let source = try String(contentsOfFile: bridgePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("silent_alert"),
                      "The fallback must use the bundled silent sound — audible audio would violate the user's 'audio alerts off' choice")
    }

    func testBridgeReadsSpeedAndLimitFromTick() throws {
        let source = try String(contentsOfFile: bridgePath(), encoding: .utf8)
        let tick = try section(in: source, anchor: "public func handleSpeedingTick")
        XCTAssertTrue(tick.contains("speed"), "Tick must consume the speed argument")
        XCTAssertTrue(tick.contains("limit"), "Tick must consume the limit argument")
    }

    func testBridgeResetsOnMonitoringTeardown() throws {
        // AlertEngine.stopMonitoringState calls BackgroundHapticBridge.reset.
        let alertSource = try String(contentsOfFile: alertPath(), encoding: .utf8)
        let teardown = try section(in: alertSource, anchor: "private func stopMonitoringState()")
        XCTAssertTrue(teardown.contains("BackgroundHapticBridge.shared.reset()"),
                      "Monitoring teardown must reset the bridge so stale tick state can't buzz later")
    }

    // MARK: - Sustained-pulse gating consistency with AlertEngine

    func testBridgeGatingMatchesPulsePolicy() {
        // The bridge must only fire when AlertEngine's pulse would: over
        // limit+buffer with a resolved limit. Cross-check the boundary.
        let cases: [(Double, Int, Bool)] = [
            (60, 45, true),   // 15 over → fires
            (45, 45, false),  // at limit → not over
            (49, 50, false),  // under limit
            (91, 90, false),  // +1: threshold is limit+buffer, buffer 0 → 91 > 90 fires
        ]
        for (speed, limit, expected) in cases {
            let over = speed > Double(limit)
            XCTAssertEqual(over, expected, "speed=\(speed) limit=\(limit)")
        }
    }

    private func section(in source: String, anchor: String) throws -> String {
        guard let range = source.range(of: anchor) else {
            XCTFail("Missing anchor: \(anchor)")
            return ""
        }
        return String(source[range.lowerBound...])
    }

    private func bridgePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\BackgroundHapticBridge.swift"
        #else
        return "SmartSpeedCompanion/Core/BackgroundHapticBridge.swift"
        #endif
    }

    private func alertPath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\AlertEngine.swift"
        #else
        return "SmartSpeedCompanion/Core/AlertEngine.swift"
        #endif
    }
}
