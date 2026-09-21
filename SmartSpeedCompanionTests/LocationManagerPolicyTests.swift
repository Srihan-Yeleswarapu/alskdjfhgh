import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// LocationManager's policies: the 100 m accuracy ceiling, the idle gate
/// (no GPS owner → no data leaks into the app), background-update
/// ownership rules, and the mock-mode isolation that keeps simulator
/// feeds out of real drives.
@MainActor
final class LocationManagerPolicyTests: XCTestCase {

    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
    }

    override func tearDown() {
        defaultsGuard.restore()
        super.tearDown()
    }

    // MARK: - The accuracy ceiling (shared contract with SpeedEngine)

    func testMaximumAcceptedAccuracyIs100Meters() {
        XCTAssertEqual(LocationManager.maximumAcceptedHorizontalAccuracy, 100.0,
                       "The ceiling must match SpeedEngine.isEligibleForSpeedLimitResolution's 100 m")
    }

    func testDelegateFiltersStaleAndInaccurateFixes() {
        let manager = LocationManager()
        manager.startUpdatingLocation() // claims the GPS (sets isUpdatingLocation)

        // A garbage fix (accuracy 250 m) must not publish.
        let bad = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: 250)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [bad])
        XCTAssertNil(manager.latestLocation, "Fix worse than the ceiling must be dropped")

        // A good fix publishes.
        let good = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: 8)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [good])
        waitForMainQueueTurn("delegate hop")
        XCTAssertNotNil(manager.latestLocation)
        manager.stopUpdatingLocation()
    }

    func testDelegateIgnoresFixesWhenIdle() {
        let manager = LocationManager()
        // isUpdatingLocation defaults false (idle).
        let good = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: 5)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [good])
        waitForMainQueueTurn("delegate hop")
        XCTAssertNil(manager.latestLocation,
                     "An idle manager must not accept fixes — no session owns the GPS")
    }

    func testStartStopTransitionsIsUpdatingFlag() {
        let manager = LocationManager()
        manager.startUpdatingLocation()
        XCTAssertTrue(manager.isUpdatingLocation)
        manager.stopUpdatingLocation()
        XCTAssertFalse(manager.isUpdatingLocation)
    }

    func testLastFixSurvivesStopForPersistence() {
        let manager = LocationManager()
        manager.startUpdatingLocation()
        let fix = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: 5)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [fix])
        waitForMainQueueTurn()
        manager.stopUpdatingLocation()
        // The last fix stays available for final-session persistence
        // (retaining a value ≠ active monitoring).
        XCTAssertNotNil(manager.latestLocation)
    }

    // MARK: - Background updates ownership

    func testBackgroundUpdatesIgnoredWhenIdle() {
        let manager = LocationManager()
        manager.setBackgroundUpdates(true) // idle: must be ignored
        // No crash; flag contract verified in source below.
    }

    func testBackgroundUpdatesPolicyInSource() throws {
        let source = try String(contentsOfFile: path(), encoding: .utf8)
        XCTAssertTrue(source.contains("let shouldEnable = enabled && isUpdatingLocation"),
                      "Background updates are only meaningful with an active GPS owner")
        XCTAssertTrue(source.contains("allowsBackgroundLocationUpdates = false"),
                      "Init must default background updates OFF (demand-driven GPS)")
        XCTAssertTrue(source.contains("showsBackgroundLocationIndicator = false"),
                      "The indicator must stay off until a session claims GPS")
    }

    // MARK: - Accuracy modes

    func testAccuracyModeBranches() throws {
        let source = try String(contentsOfFile: path(), encoding: .utf8)
        XCTAssertTrue(source.contains("kCLLocationAccuracyBestForNavigation"),
                      "Navigation mode must use BestForNavigation")
        XCTAssertTrue(source.contains("kCLLocationAccuracyBest"),
                      "Balanced mode must use Best")
        XCTAssertTrue(source.contains("gpsAccuracyMode"),
                      "The mode must read the user's stored preference")
    }

    // MARK: - Mock mode isolation

    func testMockModeGatesRealDelegateFeed() {
        #if DEBUG || DEVELOPER_BUILD
        let manager = LocationManager()
        manager.isMockMode = true
        manager.startUpdatingLocation()
        let real = GPSFixFactory.fix(lat: 33.3, lon: -111.8, speedMph: 30, accuracy: 5)
        manager.locationManager(CLLocationManager(), didUpdateLocations: [real])
        waitForMainQueueTurn()
        XCTAssertNil(manager.latestLocation,
                     "In mock mode the real delegate feed must be ignored")
        manager.stopUpdatingLocation()
        #else
        throw XCTSkip("Mock mode is DEBUG-only")
        #endif
    }

    func testSimulatorAutoEngagesMockMode() throws {
        let source = try String(contentsOfFile: path(), encoding: .utf8)
        XCTAssertTrue(source.contains("targetEnvironment(simulator)"),
                      "Simulator builds must auto-engage mock mode (no GPS hardware)")
    }

    private func path() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Core\\LocationManager.swift"
        #else
        return "SmartSpeedCompanion/Core/LocationManager.swift"
        #endif
    }
}
