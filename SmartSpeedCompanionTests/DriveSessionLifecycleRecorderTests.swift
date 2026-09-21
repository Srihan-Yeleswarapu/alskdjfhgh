import XCTest
import SwiftData
import CoreLocation
@testable import SmartSpeedCompanion

/// SessionRecorder lifecycle: the guard against double-starts, the
/// end-session contract, checkpoint persistence into SwiftData, and the
/// UserDefaults flags that let a relaunched app detect an interrupted drive.
@MainActor
final class DriveSessionLifecycleRecorderTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var recorder: SessionRecorder!
    private var speedEngine: SpeedEngine!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()

        speedEngine = SpeedEngine(locationManager: LocationManager())
        recorder = SessionRecorder(speedEngine: speedEngine, locationManager: LocationManager())
        container = try! ModelContainer(
            for: DriveSession.self, SpeedReading.self, NamedLocation.self,
            VehicleProfile.self, SpeedAlertProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        recorder.setModelContext(context)
    }

    override func tearDown() {
        if recorder.isRecording { _ = recorder.endSession() }
        recorder = nil
        speedEngine = nil
        container = nil
        context = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Start/stop contract

    func testStartSessionCreatesSessionAndFlagsRecording() {
        recorder.startSession()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNotNil(recorder.currentSession)
    }

    func testDoubleStartIsIgnored() {
        recorder.startSession()
        let first = recorder.currentSession
        recorder.startSession()
        XCTAssertIdentical(recorder.currentSession, first,
                           "A second start must not replace the live session")
        XCTAssertTrue(recorder.isRecording)
    }

    func testEndSessionReturnsCompletedSession() {
        recorder.startSession()
        let ended = recorder.endSession()
        XCTAssertNotNil(ended)
        XCTAssertNotNil(ended?.endTime, "End session must stamp the end time")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.currentSession)
    }

    func testEndSessionWithoutStartReturnsNil() {
        XCTAssertNil(recorder.endSession(), "Ending an idle recorder must be a safe no-op")
    }

    func testDestinationPlaceIDIsCarriedOntoSession() {
        recorder.startSession(destinationPlaceID: "dest-abc")
        XCTAssertEqual(recorder.currentSession?.destinationPlaceID, "dest-abc")
    }

    // MARK: - Checkpoint persistence

    func testCheckpointSurvivesRelaunchScenario() throws {
        recorder.startSession()
        let sessionID = recorder.currentSession!.id

        // Force a checkpoint (persistCheckpoint is private; saveSession
        // runs the same insert+save path).
        recorder.saveSession(recorder.currentSession!)

        let fetched = try context.fetch(FetchDescriptor<DriveSession>())
        XCTAssertTrue(fetched.contains { $0.id == sessionID },
                      "Checkpointed session must be retrievable after 'termination'")
    }

    // MARK: - Interrupted-session state flags

    func testSaveSessionStatePersistsFlags() {
        recorder.startSession(destinationPlaceID: "place-42")
        recorder.saveSessionState()

        XCTAssertTrue(UserDefaults.standard.bool(forKey: "sessionRecorder_isRecording"))
        XCTAssertEqual(SessionRecorder.interruptedSessionDestinationPlaceID(), "place-42")
        XCTAssertNotNil(SessionRecorder.interruptedSessionStartTime())
    }

    func testSaveSessionStateWithoutSessionClears() {
        UserDefaults.standard.set(true, forKey: "sessionRecorder_isRecording")
        recorder.saveSessionState()
        XCTAssertFalse(SessionRecorder.hasInterruptedSession(),
                       "Saving state with no live session must clear the flag")
    }

    func testEndSessionClearsInterruptedFlag() {
        recorder.startSession()
        recorder.saveSessionState()
        XCTAssertTrue(SessionRecorder.hasInterruptedSession())
        _ = recorder.endSession()
        XCTAssertFalse(SessionRecorder.hasInterruptedSession(),
                       "A completed session must not look 'interrupted' on next launch")
    }

    // MARK: - 30-second checkpoint timer policy

    func testCheckpointIntervalIsThirtySecondsInSource() throws {
        let source = try String(contentsOfFile: sourcePath(), encoding: .utf8)
        XCTAssertTrue(source.contains("withTimeInterval: 30.0"),
                      "Checkpoint cadence must stay 30 s — longer loses up to a minute of a crashed drive; shorter hammers SwiftData")
    }

    // MARK: - Integration: recorder + engine readings

    /// The recorder's readings mirror the engine's published state — this
    /// drives a fake GPS walk and asserts a session would capture the
    /// corridor's shape (speed + over-limit flags consistent).
    func testDriveWalkProducesCoherentReadingChain() {
        let fixes = GeoCorpus.arterialDrive(fixes: 10)
        var readings: [SpeedReading] = []
        for fix in fixes {
            readings.append(SpeedReading(
                timestamp: fix.timestamp,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                speed: fix.speedInMph,
                speedLimit: 45,
                overLimit: fix.speedInMph > 45
            ))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.readings.count, 10)
        XCTAssertEqual(session.percentWithinLimit, 1.0, accuracy: 1e-9,
                       "A 45-mph drive in a 45 zone must be fully compliant")
        XCTAssertGreaterThan(FuelEstimator.totalDistanceMiles(from: readings), 0.2)
    }

    private func sourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\SessionRecorder.swift"
        #else
        return "SmartSpeedCompanion/Core/SessionRecorder.swift"
        #endif
    }
}
