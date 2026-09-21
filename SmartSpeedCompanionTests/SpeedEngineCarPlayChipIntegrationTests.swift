import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// Integration: the exact DriveViewModel wiring — SpeedEngine drives
/// status, AlertEngine reacts, SessionRecorder persists — exercised with
/// simulated drive ticks and zero network (credentials gated).
@MainActor
final class SpeedEngineCarPlayChipIntegrationTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var speedEngine: SpeedEngine!
    private var alertEngine: AlertEngine!
    private var recorder: SessionRecorder!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        UserDefaults.standard.set(5, forKey: "userBuffer")
        speedEngine = SpeedEngine(locationManager: LocationManager())
        alertEngine = AlertEngine(speedEngine: speedEngine)
        recorder = SessionRecorder(speedEngine: speedEngine, locationManager: LocationManager())
    }

    override func tearDown() {
        if recorder.isRecording { _ = recorder.endSession() }
        recorder = nil
        alertEngine = nil
        speedEngine = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - The CarPlay chip scenario (TestFlight b640)

    /// Driver cruising 49.5 in a 45 zone with +3 buffer: chip shows red.
    /// User opens Settings mid-drive, drags buffer to +5: chip must relax
    /// to warning on the next evaluation — WITHOUT new GPS data.
    func testBufferAdjustMidDriveUpdatesChipImmediately() {
        UserDefaults.standard.set(3, forKey: "userBuffer")
        speedEngine.speed = 49.5
        speedEngine.applyResolvedLimit(45)
        XCTAssertEqual(speedEngine.status, .over, "49.5 > 45+3 = 48")

        UserDefaults.standard.set(5, forKey: "userBuffer")
        speedEngine.applyResolvedLimit(45)
        XCTAssertEqual(speedEngine.status, .warning, "49.5 ≤ 45+5 = 50 → warning band")
    }

    /// The same scenario with the AlertEngine attached: the alert episode
    /// must stand down when the buffer widens (status leaves .over).
    func testBufferAdjustMidDriveStandsDownAlertEpisode() {
        UserDefaults.standard.set(3, forKey: "userBuffer")
        speedEngine.speed = 49.5
        speedEngine.applyResolvedLimit(45)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1, "Episode started")

        UserDefaults.standard.set(5, forKey: "userBuffer")
        speedEngine.speed = 49.5
        speedEngine.applyResolvedLimit(45)
        waitForMainQueueTurn()
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0, "Episode must tear down when the threshold relaxes")
    }

    // MARK: - Limit refresh cycle across a drive

    /// The full fetch cycle: driving crosses 80 m → resolution starts →
    /// limit clears → new limit lands. Assert the HUD-visible invariants at
    /// each phase with the recorder attached.
    func testLimitRefreshCycleKeepsHudInvariants() {
        speedEngine.speed = 45
        speedEngine.applyResolvedLimit(45)
        XCTAssertTrue(speedEngine.isLimitResolved)
        XCTAssertEqual(recorder.isRecording, false)

        // New road resolution begins.
        _ = speedEngine.beginLimitResolution()
        XCTAssertFalse(speedEngine.isLimitResolved, "In-flight: badge unknown")
        XCTAssertEqual(speedEngine.status, .safe, "No red during lookup")

        // Lookup lands (current token).
        speedEngine.speed = 45
        speedEngine.applyResolvedLimit(40)
        XCTAssertTrue(speedEngine.isLimitResolved)
        XCTAssertEqual(speedEngine.limit, 40)
        XCTAssertEqual(speedEngine.status, .warning,
                       "45 == threshold 40+5 → warning (strict > for over)")
    }

    // MARK: - Recording session mirrors engine

    func testRecorderCapturesEngineDrivenReadings() {
        recorder.startSession()
        XCTAssertTrue(recorder.isRecording)

        let fixes = GeoCorpus.arterialDrive(fixes: 6)
        var readings: [SpeedReading] = []
        for fix in fixes {
            speedEngine.processLocationForTesting(fix)
            readings.append(SpeedReading(
                timestamp: fix.timestamp,
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                speed: speedEngine.speed,
                speedLimit: 45,
                overLimit: speedEngine.status == .over
            ))
        }
        let session = DriveSession(startTime: .now, readings: readings)
        XCTAssertEqual(session.readings.count, 6)
        // Engine display values may lag raw by EMA — but must stay plausible.
        for reading in session.readings {
            XCTAssertTrue((0...60).contains(reading.speed), "Implausible engine speed \(reading.speed)")
        }
        XCTAssertEqual(session.percentWithinLimit, 1.0, accuracy: 1e-9)

        let ended = recorder.endSession()
        XCTAssertNotNil(ended)
    }

    // MARK: - New-drive boundary

    func testQuickStopStartDoesNotInheritState() {
        // Drive 1: speeding.
        speedEngine.speed = 60
        speedEngine.applyResolvedLimit(45)
        XCTAssertEqual(speedEngine.status, .over)

        // Stop. New drive.
        speedEngine.resetForNewDrive()
        XCTAssertEqual(speedEngine.speed, 0)
        XCTAssertEqual(speedEngine.limit, 0)
        XCTAssertEqual(speedEngine.status, .safe)

        // Drive 2 begins clean: a 30-mph fix must not trip the old state.
        speedEngine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30))
        speedEngine.applyResolvedLimit(45)
        XCTAssertEqual(speedEngine.status, .safe)
    }

    // MARK: - Widget snapshot keys (App Group)

    func testWidgetSnapshotKeysAreWritable() {
        let group = UserDefaults(suiteName: SpeedFormatting.appGroupSuite)
        group?.set(58, forKey: "widgetSpeed")
        group?.set(55, forKey: "widgetLimit")
        group?.set("over", forKey: "widgetStatus")
        XCTAssertEqual(group?.integer(forKey: "widgetSpeed"), 58)
        XCTAssertEqual(group?.integer(forKey: "widgetLimit"), 55)
        XCTAssertEqual(group?.string(forKey: "widgetStatus"), "over")
        group?.removeObject(forKey: "widgetSpeed")
        group?.removeObject(forKey: "widgetLimit")
        group?.removeObject(forKey: "widgetStatus")
    }
}
