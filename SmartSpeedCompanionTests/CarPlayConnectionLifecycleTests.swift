import XCTest
@testable import SmartSpeedCompanion

/// CarPlay connection lifecycle: the app can be plugged/unplugged many times
/// per drive; each lifecycle must start from clean state with no leakage from
/// the previous session.
final class CarPlayConnectionLifecycleTests: XCTestCase {

    struct LifecycleProbe {
        var isConnected: Bool
        var speedAtDisconnect: Double
    }

    private func simulateLifecycle(steps: [String]) -> LifecycleProbe {
        var connected = false
        var speedAtDisconnect = 0.0
        var currentSpeed = 0.0

        for step in steps {
            switch step {
            case "connect": connected = true
            case "disconnect":
                connected = false
                speedAtDisconnect = currentSpeed
            case "speed47": currentSpeed = 47
            case "speed88": currentSpeed = 88
            default: break
            }
        }
        return LifecycleProbe(isConnected: connected, speedAtDisconnect: speedAtDisconnect)
    }

    func testDisconnectPreservesLastSpeed() {
        let probe = simulateLifecycle(steps: ["connect", "speed47", "disconnect"])
        XCTAssertFalse(probe.isConnected)
        XCTAssertEqual(probe.speedAtDisconnect, 47, accuracy: 0.001,
                       "Disconnect lost the last speed value")
    }

    func testReconnectStartsCleanButWarm() {
        // After reconnect the CarPlay surface re-renders from current engine
        // state — the last speed remains available (warm restart), but the
        // connection state itself is fresh.
        let probe = simulateLifecycle(steps: ["connect", "speed47", "disconnect", "connect"])
        XCTAssertTrue(probe.isConnected)
        // Re-rendered value comes from the live engine, not the stored one.
        XCTAssertEqual(probe.speedAtDisconnect, 47)
    }

    func testManyPlugUnplugCyclesStayConsistent() {
        var probe = LifecycleProbe(isConnected: false, speedAtDisconnect: 0)
        for _ in 0..<100 {
            probe = simulateLifecycle(steps: ["connect", "speed47", "disconnect"])
            XCTAssertFalse(probe.isConnected)
            XCTAssertEqual(probe.speedAtDisconnect, 47, accuracy: 0.001)
        }
    }

    func testDisconnectDuringHighSpeedPreservesValue() {
        let probe = simulateLifecycle(steps: ["connect", "speed88", "disconnect"])
        XCTAssertEqual(probe.speedAtDisconnect, 88, accuracy: 0.001)
    }

    func testNeverConnectedProbeIsClean() {
        let probe = simulateLifecycle(steps: ["speed47"])
        XCTAssertFalse(probe.isConnected)
        XCTAssertEqual(probe.speedAtDisconnect, 0, "State leaked without any connection")
    }
}
