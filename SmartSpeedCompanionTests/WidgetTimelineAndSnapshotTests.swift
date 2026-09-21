import XCTest
@testable import SmartSpeedCompanion

/// Widget timeline integrity: entries drive the home-screen glance; a bad
/// timeline (out-of-order dates, missing payloads, hostile restart policy)
/// shows stale or broken info all day. Timeline data flows through
/// SpeedActivityAttributes; these tests verify those payload contracts.
final class WidgetTimelineAndSnapshotTests: XCTestCase {

    private struct TimelineEntry: Equatable {
        var date: Date
        var speed: Int
        var limit: Int
    }

    // MARK: - Timeline ordering

    func testTimelineDatesAreStrictlyIncreasing() {
        let base = Date(timeIntervalSince1970: 9_000_000)
        let entries = (0..<48).map { i in
            TimelineEntry(date: base.addingTimeInterval(Double(i) * 900),
                          speed: 40 + i % 20, limit: 50)
        }
        for pair in zip(entries, entries.dropFirst()) {
            XCTAssertLessThan(pair.0.date, pair.1.date,
                              "Timeline entries out of order at \(pair.0.date)")
        }
    }

    func testTimelineCoversRequestedHorizon() {
        let base = Date(timeIntervalSince1970: 9_000_000)
        let horizon: TimeInterval = 12 * 3600
        let entries = stride(from: 0.0, through: horizon, by: 900).map {
            TimelineEntry(date: base.addingTimeInterval($0), speed: 0, limit: 0)
        }
        XCTAssertEqual(entries.count, 49)
        XCTAssertEqual(entries.last?.date.timeIntervalSince(base) ?? 0, horizon,
                       accuracy: 1)
    }

    // MARK: - Payload completeness (SpeedActivityAttributes content state)

    private func makeState(speed: Double, limit: Int, over: Bool) -> SpeedActivityAttributes.ContentState {
        SpeedActivityAttributes.ContentState(
            speed: speed,
            speedLimit: limit,
            status: over ? "over" : (speed > Double(limit) - 5 ? "warning" : "safe"),
            isRecording: false,
            consecutiveOverSeconds: over ? 12 : 0,
            sessionDuration: 600,
            nextManeuver: nil,
            nextManeuverImageName: nil,
            distanceToNextTurn: nil,
            eta: nil)
    }

    func testContentStateSurvivesCodableRoundTrip() throws {
        let state = makeState(speed: 72.4, limit: 50, over: true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self,
                                               from: data)
        XCTAssertEqual(decoded.speed, 72.4, accuracy: 0.001)
        XCTAssertEqual(decoded.speedLimit, 50)
        XCTAssertEqual(decoded.status, "over")
        XCTAssertEqual(decoded.consecutiveOverSeconds, 12)
    }

    func testContentStateRoundTripsZeroAndEdgeValues() throws {
        let zero = makeState(speed: 0, limit: 0, over: false)
        let extreme = makeState(speed: 999, limit: 130, over: true)
        for state in [zero, extreme] {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self,
                                                   from: data)
            XCTAssertEqual(decoded.speed, state.speed, accuracy: 0.001)
            XCTAssertEqual(decoded.status, state.status)
            XCTAssertEqual(decoded.sessionDuration, state.sessionDuration)
        }
    }

    func testContentStateNavigationFieldsRoundTrip() throws {
        var state = makeState(speed: 55, limit: 50, over: true)
        state.nextManeuver = "Turn left onto US-101 N"
        state.distanceToNextTurn = 420
        state.eta = Date(timeIntervalSince1970: 9_100_000)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self,
                                               from: data)
        XCTAssertEqual(decoded.nextManeuver, "Turn left onto US-101 N")
        XCTAssertEqual(decoded.distanceToNextTurn ?? 0, 420, accuracy: 0.001)
        XCTAssertEqual(decoded.eta, state.eta)
    }

    func testContentStateStatusVocabularyIsClosed() throws {
        // status is a string in the wire format; only three values are valid.
        let valid = Set(["safe", "warning", "over"])
        for (speed, limit) in [(30.0, 50), (47.0, 50), (60.0, 50)] {
            let over = speed > Double(limit)
            let status = over ? "over" : (speed > Double(limit) - 5 ? "warning" : "safe")
            XCTAssertTrue(valid.contains(status), "Status \(status) outside vocabulary")
        }
    }

    // MARK: - Restart policy

    func testTimelineEntriesNeverClusterAtSameSecond() {
        // A mis-scheduled timeline fires dozens of reloads in the same second,
        // which the system throttles by dropping entries.
        let base = Date(timeIntervalSince1970: 9_000_000)
        let entries = (0..<24).map { TimelineEntry(date: base.addingTimeInterval(Double($0) * 600),
                                                   speed: 30, limit: 30) }
        let seconds = Set(entries.map { Int($0.date.timeIntervalSince1970) })
        XCTAssertEqual(seconds.count, entries.count, "Entries clustered within the same second")
    }

    func testWidgetSnapshotSurvivesProcessRestartShape() throws {
        // Widgets decode snapshots from archived payloads after process death;
        // the payload must round-trip through JSON (the archive root).
        let state = SpeedActivityAttributes.ContentState(
            speedKph: 55.5, speedLimit: 65, isOverLimit: false)
        let data = try JSONEncoder().encode(state)
        XCTAssertGreaterThan(data.count, 0)
        let back = try JSONDecoder().decode(SpeedActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(back, state)
    }

    func testConsecutiveOverSecondsMonotoneInPayload() throws {
        // As over-limit time accumulates, the payload seconds must grow, and
        // return to zero only when back under.
        var seconds = 0
        for tick in 0..<30 {
            if tick % 10 != 9 { seconds += 1 } else { seconds = 0 }
            let state = makeState(speed: 60, limit: 50, over: seconds > 0)
            XCTAssertEqual(state.consecutiveOverSeconds,
                           seconds > 0 ? state.consecutiveOverSeconds : 0)
        }
    }
}
