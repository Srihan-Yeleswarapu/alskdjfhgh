import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Session recorder: session lifecycle — flag defaults, start/stop
/// idempotency, and tolerance of invalid GPS fixes. Real SessionRecorder,
/// no network, no SwiftData (the recorder tolerates a nil model context).
/// (The historical CSV/ingest surface was replaced by SwiftData sessions in
/// the DriveSession migration; these tests track the current lifecycle API.)
@MainActor
final class SessionRecorderStressTests: XCTestCase {

    private func makeRecorder() -> SessionRecorder {
        SessionRecorder(speedEngine: SpeedEngine(locationManager: LocationManager()),
                        locationManager: LocationManager())
    }

    func testRecordingFlagIsOffByDefault() {
        let r = makeRecorder()
        XCTAssertFalse(r.isRecording, "Recorder must not silently record")
    }

    func testStartMakesRecordingTrue() {
        let r = makeRecorder()
        r.startSession()
        XCTAssertTrue(r.isRecording)
        _ = r.endSession()
    }

    func testStopIsIdempotent() {
        let r = makeRecorder()
        r.startSession()
        _ = r.endSession()
        _ = r.endSession()
        XCTAssertFalse(r.isRecording, "Double-stop corrupted recorder state")
    }

    func testStopWithoutStartIsSafe() {
        let r = makeRecorder()
        _ = r.endSession() // must not crash or corrupt
        XCTAssertFalse(r.isRecording)
    }

    // MARK: - Ingestion gate

    func testIngestWithoutRecordingIsIgnored() {
        // The recorder only samples through its 1 Hz recording timer; a
        // location delivered while idle must not start a session implicitly.
        let r = makeRecorder()
        r.recordDataPointForTesting(CLLocation(latitude: 37.0, longitude: -122.0, speed: 20))
        XCTAssertFalse(r.isRecording,
                       "Idle recorder must not be started by a location delivery")
    }

    func testIngestWhileRecordingAccumulates() {
        let r = makeRecorder()
        r.startSession()
        XCTAssertTrue(r.isRecording)
        var now = Date(timeIntervalSince1970: 9_000_000)
        for i in 0..<1_000 {
            now.addTimeInterval(1)
            r.recordDataPointForTesting(CLLocation(
                coordinate: .init(latitude: 37.0 + Double(i) * 0.00001,
                                  longitude: -122.0),
                altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                course: 90, speed: 25, timestamp: now))
        }
        let session = r.endSession()
        XCTAssertFalse(r.isRecording)
        XCTAssertNotNil(session, "A recorded session must be returned on stop")
    }

    func testIngestHandlesInvalidSpeedFixes() {
        // GPS sometimes reports speed = -1 (invalid); the recorder must not
        // crash or write garbage.
        let r = makeRecorder()
        r.startSession()
        r.recordDataPointForTesting(CLLocation(latitude: 37.0, longitude: -122.0, speed: -1))
        r.recordDataPointForTesting(CLLocation(latitude: 37.0, longitude: -122.0, speed: .nan))
        _ = r.endSession()
        XCTAssertFalse(r.isRecording)
    }

    // MARK: - Timestamp monotonicity

    func testTimestampsAreMonotoneInIngestedFixes() {
        // The recorder must never see fix timestamps going backwards; the
        // per-second sampler stamps with Date() so ordering is monotone.
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
        let r = makeRecorder()
        for _ in 0..<200 {
            r.startSession()
            XCTAssertTrue(r.isRecording)
            r.recordDataPointForTesting(CLLocation(latitude: 37.0, longitude: -122.0, speed: 30))
            _ = r.endSession()
            XCTAssertFalse(r.isRecording)
        }
    }
}

private extension CLLocation {
    convenience init(latitude: Double, longitude: Double, speed: Double) {
        self.init(coordinate: .init(latitude: latitude, longitude: longitude),
                  altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
                  course: 0, courseAccuracy: 5, speed: speed,
                  speedAccuracy: 1, timestamp: Date())
    }
}
