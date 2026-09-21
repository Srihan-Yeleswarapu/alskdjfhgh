import XCTest
import SwiftData
@testable import SmartSpeedCompanion

/// DriveSession's computed analytics drive the safety report and drive
/// history. Every formula here is verified against hand-computed scenarios:
/// percentWithinLimit, longestOverstreak, maxSpeed, maxOverLimit,
/// avgMphOverLimit, drivingScore, and the title formatter.
@MainActor
final class DriveSessionAnalyticsIntegrityTests: XCTestCase {

    // MARK: - Fixtures

    private func reading(speed: Double, limit: Int, over: Bool? = nil,
                         lat: Double = 33.3, lon: Double = -111.8,
                         timestamp: Date? = nil) -> SpeedReading {
        SpeedReading(
            timestamp: timestamp ?? .now,
            latitude: lat, longitude: lon,
            speed: speed, speedLimit: limit,
            overLimit: over ?? (limit > 0 && speed > Double(limit))
        )
    }

    // MARK: - percentWithinLimit

    func testPercentWithinLimitEmptySessionIsOne() {
        let session = DriveSession(startTime: .now)
        XCTAssertEqual(session.percentWithinLimit, 1.0,
                       "No readings = no violations = perfect compliance")
    }

    func testPercentWithinLimitHalfOver() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 30, limit: 45),
            reading(speed: 50, limit: 45, over: true),
        ])
        XCTAssertEqual(session.percentWithinLimit, 0.5, accuracy: 1e-9)
    }

    func testPercentWithinLimitAllOver() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 60, limit: 45, over: true),
            reading(speed: 70, limit: 45, over: true),
        ])
        XCTAssertEqual(session.percentWithinLimit, 0.0)
    }

    // MARK: - longestOverstreak

    func testLongestStreakFindsTheLongestRun() {
        let over = [true, true, false, true, true, true, false, true]
        let readings = over.enumerated().map { idx, flag in
            reading(speed: flag ? 60 : 30, limit: 45, over: flag,
                    timestamp: Date(timeIntervalSinceNow: TimeInterval(idx)))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.longestOverstreak, 3)
    }

    func testLongestStreakAllOverCountsEverything() {
        let readings = (0..<10).map { idx in
            reading(speed: 60, limit: 45, over: true,
                    timestamp: Date(timeIntervalSinceNow: TimeInterval(idx)))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.longestOverstreak, 10)
    }

    func testLongestStreakNoneOver() {
        let readings = (0..<10).map { idx in
            reading(speed: 30, limit: 45,
                    timestamp: Date(timeIntervalSinceNow: TimeInterval(idx)))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.longestOverstreak, 0)
    }

    // MARK: - maxSpeed / maxOverLimit

    func testMaxSpeed() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 35, limit: 45), reading(speed: 52, limit: 45, over: true),
            reading(speed: 48, limit: 45, over: true),
        ])
        XCTAssertEqual(session.maxSpeed, 52)
    }

    func testMaxSpeedEmptyIsZero() {
        XCTAssertEqual(DriveSession(startTime: .now).maxSpeed, 0)
    }

    func testMaxOverLimitUsesOnlyOverReadings() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 30, limit: 45),                    // not over
            reading(speed: 50, limit: 45, over: true),        // +5
            reading(speed: 58, limit: 45, over: true),        // +13 ← max
            reading(speed: 52, limit: 45, over: true),        // +7
        ])
        XCTAssertEqual(session.maxOverLimit, 13)
    }

    func testMaxOverLimitZeroWhenNeverOver() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 30, limit: 45), reading(speed: 44, limit: 45),
        ])
        XCTAssertEqual(session.maxOverLimit, 0)
    }

    func testMaxOverLimitIgnoresUnknownLimitReadings() {
        // A reading flagged over with limit 0 is bookkeeping noise; it must
        // not produce a phantom "+80 over" on the report.
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 80, limit: 0, over: true),
            reading(speed: 50, limit: 45, over: true),
        ])
        XCTAssertEqual(session.maxOverLimit, 5, "Unknown-limit readings must be excluded from maxOverLimit")
    }

    // MARK: - avgMphOverLimit

    func testAvgOverLimitIsMeanOfOverReadings() {
        let session = DriveSession(startTime: .now, readings: [
            reading(speed: 50, limit: 45, over: true),  // +5
            reading(speed: 58, limit: 45, over: true),  // +13
            reading(speed: 30, limit: 45),              // ignored
        ])
        XCTAssertEqual(session.avgMphOverLimit, 9.0, accuracy: 1e-9)
    }

    func testAvgOverLimitZeroWithoutViolations() {
        let session = DriveSession(startTime: .now, readings: [reading(speed: 30, limit: 45)])
        XCTAssertEqual(session.avgMphOverLimit, 0)
    }

    // MARK: - drivingScore

    func testPerfectDriveScores100() {
        let readings = (0..<100).map { idx in
            reading(speed: 40, limit: 45, timestamp: Date(timeIntervalSinceNow: TimeInterval(idx)))
        }
        XCTAssertEqual(DriveSession(startTime: .now, readings: readings).drivingScore, 100)
    }

    func testEmptySessionScores100() {
        XCTAssertEqual(DriveSession(startTime: .now).drivingScore, 100)
    }

    /// Hand-computed: 20% of time over, avg +4 mph over, no long streak.
    /// score = 100 − (20 × (1 + 4/8)) − 0 = 100 − 30 = 70.
    func testScoreFormulaHandComputed() {
        var readings: [SpeedReading] = []
        for idx in 0..<10 {
            if idx < 2 {
                readings.append(reading(speed: 49, limit: 45, over: true,
                                        timestamp: Date(timeIntervalSinceNow: TimeInterval(idx))))
            } else {
                readings.append(reading(speed: 40, limit: 45,
                                        timestamp: Date(timeIntervalSinceNow: TimeInterval(idx))))
            }
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.percentWithinLimit, 0.8, accuracy: 1e-9)
        XCTAssertEqual(session.avgMphOverLimit, 4.0, accuracy: 1e-9)
        XCTAssertEqual(session.longestOverstreak, 2)
        XCTAssertEqual(session.drivingScore, 70)
    }

    /// Streak penalty caps at 20 points: min(20, streak/5).
    func testStreakPenaltyCap() {
        var readings: [SpeedReading] = []
        for idx in 0..<200 {
            // 150 consecutive over-readings: penalty would be 30 uncapped.
            readings.append(reading(speed: idx < 150 ? 60 : 30, limit: 45,
                                    over: idx < 150,
                                    timestamp: Date(timeIntervalSinceNow: TimeInterval(idx))))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.longestOverstreak, 150)
        // 75% over, avg over +15 → severity 1 + 15/8 = 2.875
        // raw = 100 − (75 × 2.875) − 20 = 100 − 215.6 − 20 → clamps to 0.
        XCTAssertEqual(session.drivingScore, 0, "Severe sessions must clamp to 0, not go negative")
    }

    func testScoreNeverExceeds100() {
        // Pathological input: over flags without excess speed.
        let readings = (0..<50).map { idx in
            reading(speed: 45.01, limit: 45, over: true,
                    timestamp: Date(timeIntervalSinceNow: TimeInterval(idx)))
        }
        let score = DriveSession(startTime: .now, readings: readings).drivingScore
        XCTAssertTrue((0...100).contains(score))
    }

    // MARK: - Duration + title

    func testDurationUsesEndTime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = DriveSession(startTime: start)
        session.endTime = start.addingTimeInterval(1800)
        XCTAssertEqual(session.durationSeconds, 1800, accuracy: 1)
    }

    func testTitleUsesCustomTitleWhenSet() {
        let session = DriveSession(startTime: .now)
        session.customTitle = "  "
        XCTAssertNotEqual(session.title, "  ", "Whitespace custom title must fall through to computed")
        session.customTitle = "Commute"
        XCTAssertEqual(session.title, "Commute")
    }

    func testTitleFallsBackWhenGeocodeUnknown() {
        let session = DriveSession(startTime: .now)
        session.startLocationName = "Unknown Location"
        session.endLocationName = "Office"
        XCTAssertTrue(session.title.hasPrefix("Drive Session"),
                      "'Unknown Location' must not appear in the title")
    }

    func testTitleJoinsStartAndEnd() {
        let session = DriveSession(startTime: .now)
        session.startLocationName = "Home"
        session.endLocationName = "Office"
        XCTAssertTrue(session.title.hasPrefix("Home to Office"))
    }

    // MARK: - SwiftData round-trip (in-memory store)

    func testSessionPersistsAndRelloadsThroughSwiftData() throws {
        let container = try ModelContainer(
            for: DriveSession.self, SpeedReading.self, NamedLocation.self,
            VehicleProfile.self, SpeedAlertProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let session = DriveSession(startTime: .now)
        session.readings = [
            reading(speed: 30, limit: 45),
            reading(speed: 55, limit: 45, over: true),
        ]
        context.insert(session)
        try context.save()

        let descriptor = FetchDescriptor<DriveSession>()
        let loaded = try context.fetch(descriptor)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.readings.count, 2, "Cascade relationship must persist readings")
        XCTAssertEqual(loaded.first?.maxSpeed, 55)
    }

    func testInterruptedSessionFlagRoundTrip() {
        UserDefaults.standard.set(true, forKey: "sessionRecorder_isRecording")
        XCTAssertTrue(SessionRecorder.hasInterruptedSession())
        let start = Date()
        UserDefaults.standard.set(start, forKey: "sessionRecorder_sessionStartTime")
        UserDefaults.standard.set("place-123", forKey: "sessionRecorder_destinationPlaceID")
        XCTAssertEqual(SessionRecorder.interruptedSessionStartTime(), start)
        XCTAssertEqual(SessionRecorder.interruptedSessionDestinationPlaceID(), "place-123")
        UserDefaults.standard.removeObject(forKey: "sessionRecorder_isRecording")
        XCTAssertFalse(SessionRecorder.hasInterruptedSession())
    }
}
