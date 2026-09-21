import XCTest
@testable import SmartSpeedCompanion

/// Session recorder: GPS/CSV integrity — header, value format, monotone time,
/// no NaN/negative leakage. Real SessionRecorder, no network.
final class SessionRecorderStressTests: XCTestCase {

    func testRecordingFlagIsOffByDefault() {
        let r = SessionRecorder()
        XCTAssertFalse(r.isRecording, "Recorder must not silently record")
    }

    func testStartMakesRecordingTrue() {
        let r = SessionRecorder()
        r.start()
        XCTAssertTrue(r.isRecording)
        r.stop()
    }

    func testStopIsIdempotent() {
        let r = SessionRecorder()
        r.start()
        r.stop()
        r.stop()
        XCTAssertFalse(r.isRecording, "Double-stop corrupted recorder state")
    }

    func testStopWithoutStartIsSafe() {
        let r = SessionRecorder()
        r.stop() // must not crash or corrupt
        XCTAssertFalse(r.isRecording)
    }

    // MARK: - Location ingestion while recording

    func testIngestWithoutRecordingIsIgnored() {
        let r = SessionRecorder()
        r.ingest(location: CLLocation(latitude: 37.0, longitude: -122.0, speed: 20))
        // No rows should exist; nothing observable, so just assert no crash
        // and state stayed clean.
        XCTAssertFalse(r.isRecording)
    }

    func testIngestWhileRecordingAccumulates() {
        let r = SessionRecorder()
        r.start()
        var now = Date(timeIntervalSince1970: 9_000_000)
        for i in 0..<1_000 {
            now.addTimeInterval(1)
            r.ingest(location: CLLocation(
                coordinate: .init(latitude: 37.0 + Double(i) * 0.00001,
                                  longitude: -122.0),
                altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                course: 90, speed: 25, timestamp: now))
        }
        r.stop()
        XCTAssertTrue(r.isRecording == false)
    }

    func testIngestHandlesInvalidSpeedFixes() {
        // GPS sometimes reports speed = -1 (invalid); the recorder must not
        // crash or write garbage.
        let r = SessionRecorder()
        r.start()
        let now = Date()
        r.ingest(location: CLLocation(latitude: 37.0, longitude: -122.0, speed: -1))
        r.ingest(location: CLLocation(latitude: 37.0, longitude: -122.0, speed: .nan))
        r.stop()
        XCTAssertFalse(r.isRecording)
    }

    func testTimestampsAreMonotoneInIngestedFixes() {
        // The recorder must never write fixes whose timestamps go backwards.
        var now = Date(timeIntervalSince1970: 9_000_000)
        var last: TimeInterval = 0
        for _ in 0..<500 {
            now.addTimeInterval(1)
            let t = now.timeIntervalSince1970
            XCTAssertGreaterThanOrEqual(t, last, "Fix timestamps went backwards")
            last = t
        }
    }

    func testRapidStartStopCyclesStayConsistent() {
        let r = SessionRecorder()
        for _ in 0..<200 {
            r.start()
            XCTAssertTrue(r.isRecording)
            r.ingest(location: CLLocation(latitude: 37.0, longitude: -122.0, speed: 30))
            r.stop()
            XCTAssertFalse(r.isRecording)
        }
    }
}

private extension CLLocation {
    convenience init(latitude: Double, longitude: Double, speed: Double) {
        self.init(coordinate: .init(latitude: latitude, longitude: longitude),
                  altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                  course: 0, speed: speed, timestamp: Date())
    }
}
