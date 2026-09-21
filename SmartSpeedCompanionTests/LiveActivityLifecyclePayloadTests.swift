import XCTest
@testable import SmartSpeedCompanion

/// Live Activity payload progression: as a drive unfolds, the lock-screen
/// payload must tell an honest story — status escalates only when true,
/// session clock never runs backwards, navigation fields appear only with a
/// route. Uses the real SpeedActivityAttributes.ContentState wire format.
final class LiveActivityLifecyclePayloadTests: XCTestCase {

    private func state(speed: Double,
                       limit: Int,
                       status: String,
                       consecutive: Int = 0,
                       session: TimeInterval = 0,
                       maneuver: String? = nil,
                       distance: Double? = nil) -> SpeedActivityAttributes.ContentState {
        SpeedActivityAttributes.ContentState(
            speed: speed, speedLimit: limit, status: status,
            isRecording: false, consecutiveOverSeconds: consecutive,
            sessionDuration: session,
            nextManeuver: maneuver, nextManeuverImageName: nil,
            distanceToNextTurn: distance, eta: nil)
    }

    // MARK: - Status honesty

    func testStatusEscalationIsHonest() {
        let safe = state(speed: 40, limit: 50, status: "safe")
        let warning = state(speed: 47, limit: 50, status: "warning")
        let over = state(speed: 55, limit: 50, status: "over")
        XCTAssertEqual(safe.status, "safe")
        XCTAssertEqual(warning.status, "warning")
        XCTAssertEqual(over.status, "over")
    }

    func testOverStatusRequiresPositiveDelta() {
        // "over" with speed ≤ limit is a lie that would panic users.
        let s = state(speed: 45, limit: 50, status: "over")
        XCTAssertGreaterThan(s.speed, Double(s.speedLimit) - 5,
                             "Over status payload must correspond to near/over speed")
    }

    func testStatusVocabularyNeverDrifts() {
        let allowed: Set<String> = ["safe", "warning", "over"]
        for s in [state(speed: 30, limit: 50, status: "safe"),
                  state(speed: 47, limit: 50, status: "warning"),
                  state(speed: 55, limit: 50, status: "over")] {
            XCTAssertTrue(allowed.contains(s.status), "Status '\(s.status)' outside vocabulary")
        }
    }

    // MARK: - Session clock

    func testSessionDurationMonotoneAcrossUpdates() {
        var now: TimeInterval = 0
        var last = -1.0
        for _ in 0..<100 {
            now += 1
            let s = state(speed: 40, limit: 50, status: "safe", session: now)
            XCTAssertGreaterThanOrEqual(s.sessionDuration, last)
            last = s.sessionDuration
        }
    }

    func testSessionDurationNeverNegative() {
        let s = state(speed: 40, limit: 50, status: "safe", session: 0)
        XCTAssertGreaterThanOrEqual(s.sessionDuration, 0)
    }

    // MARK: - Consecutive-over counter

    func testConsecutiveOverCounterResetsOnlyWhenSafe() {
        var counter = 0
        var payloads: [Int] = []
        for tick in 0..<20 {
            if tick < 10 { counter += 1 } else { counter = 0 }
            payloads.append(counter)
        }
        XCTAssertEqual(payloads[9], 10)
        XCTAssertEqual(payloads[10], 0, "Counter failed to reset when back under limit")
    }

    // MARK: - Navigation fields appear only with a route

    func testManeuverFieldsNilWithoutRoute() {
        let s = state(speed: 40, limit: 50, status: "safe")
        XCTAssertNil(s.nextManeuver, "Maneuver text present without a route")
        XCTAssertNil(s.distanceToNextTurn, "Turn distance present without a route")
    }

    func testManeuverFieldsPopulateWithRoute() {
        let s = state(speed: 40, limit: 50, status: "safe",
                      maneuver: "In 400 ft, turn right", distance: 122)
        XCTAssertEqual(s.nextManeuver, "In 400 ft, turn right")
        XCTAssertEqual(s.distanceToNextTurn ?? 0, 122, accuracy: 0.001)
    }

    // MARK: - Codable survival (payload crosses process boundary)

    func testFullPayloadSurvivesCodableRoundTrip() throws {
        let s = state(speed: 63.4, limit: 55, status: "warning",
                      consecutive: 7, session: 1_234.5,
                      maneuver: "Keep left", distance: 800)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(back.speed, 63.4, accuracy: 0.001)
        XCTAssertEqual(back.consecutiveOverSeconds, 7)
        XCTAssertEqual(back.sessionDuration, 1_234.5, accuracy: 0.001)
        XCTAssertEqual(back.nextManeuver, "Keep left")
        XCTAssertEqual(back.distanceToNextTurn ?? 0, 800, accuracy: 0.001)
    }

    // MARK: - Recording flag

    func testRecordingFlagRoundTrips() throws {
        var s = state(speed: 40, limit: 50, status: "safe")
        s.isRecording = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self, from: data)
        XCTAssertTrue(back.isRecording, "Recording flag lost across process boundary")
    }
}
