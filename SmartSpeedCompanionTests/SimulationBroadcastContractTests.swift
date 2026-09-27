import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SimulationManager is the developer drive simulator: it converts mph→m/s,
/// integrates motion along the mock heading each second, road-snaps through
/// `SimulationDataSource`, and broadcasts `didUpdateMockLocation` for
/// LocationManager to intercept. These tests exercise the real broadcast loop
/// (real 1 s timer on the main run loop) — no stubbing of the pipeline.
///
/// Note: SimulationManager is compiled `#if DEBUG || DEVELOPER_BUILD`, which
/// holds for the test build. All state lives on the shared singleton, so every
/// test cleans up in tearDown.
@MainActor
final class SimulationBroadcastContractTests: XCTestCase {

    private final class FixedRouteSource: SimulationDataSource {
        var snap: CLLocationCoordinate2D?
        var roadHeading: Double?
        var calls = 0

        func getNearestPointOnRoute(to coordinate: CLLocationCoordinate2D)
            -> (coordinate: CLLocationCoordinate2D, heading: Double?) {
            calls += 1
            if let snap {
                return (snap, roadHeading)
            }
            return (coordinate, roadHeading)
        }
    }

    private var notifications: [Notification] = []
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        SimulationManager.shared.dataSource = nil
        SimulationManager.shared.isSimulationActive = false
        SimulationManager.shared.mockSpeed = 0
        SimulationManager.shared.mockHeading = 0
        SimulationManager.shared.mockCoordinate = CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740)
        notifications = []
        observer = NotificationCenter.default.addObserver(
            forName: .didUpdateMockLocation, object: nil, queue: nil
        ) { [weak self] note in self?.notifications.append(note) }
    }

    override func tearDown() {
        SimulationManager.shared.isSimulationActive = false
        SimulationManager.shared.dataSource = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        super.tearDown()
    }

    private var broadcastLocations: [CLLocation] {
        notifications.compactMap { $0.object as? CLLocation }
    }

    // MARK: - Wire contract of the broadcast

    func testBroadcastCarriesMphToMetersPerSecondConversion() {
        // 60 mph must arrive as ~26.82 m/s — LocationManager's engine filters
        // on CLLocation.speed, so a conversion bug here poisons every reading.
        SimulationManager.shared.mockSpeed = 60
        SimulationManager.shared.isSimulationActive = true

        waitBroadcasts(count: 1, timeout: 3)
        guard let loc = broadcastLocations.first else {
            return XCTFail("no broadcast received")
        }
        XCTAssertEqual(loc.speed, 60 / 2.23694, accuracy: 0.01,
                       "mph→m/s conversion wrong: \(loc.speed)")
        XCTAssertEqual(loc.horizontalAccuracy, 5.0, accuracy: 0.001,
                       "simulated fixes must carry good accuracy to pass engine filters")
        XCTAssertEqual(loc.verticalAccuracy, 5.0, accuracy: 0.001)
    }

    func testBroadcastCarriesMockHeadingAsCourse() {
        SimulationManager.shared.mockHeading = 273.0
        SimulationManager.shared.mockSpeed = 30
        SimulationManager.shared.isSimulationActive = true

        waitBroadcasts(count: 1, timeout: 3)
        XCTAssertEqual(broadcastLocations.first?.course ?? -1, 273.0, accuracy: 0.01)
    }

    func testBroadcastTimestampIsFresh() {
        SimulationManager.shared.mockSpeed = 30
        SimulationManager.shared.isSimulationActive = true
        let start = Date()

        waitBroadcasts(count: 1, timeout: 3)
        let ts = broadcastLocations.first?.timestamp ?? .distantPast
        XCTAssertGreaterThan(ts, start.addingTimeInterval(-2), "stale timestamp broadcast")
        XCTAssertLessThanOrEqual(ts.timeIntervalSinceNow, 2)
    }

    // MARK: - Motion integration

    func testPhysicsIntegratesEastwardMotionPerTick() {
        // Heading 90° (east), 60 mph → ~26.8 m per tick. After ~2.3 s of live
        // ticking the mock must have moved east, latitude ~unchanged.
        SimulationManager.shared.mockSpeed = 60
        SimulationManager.shared.mockHeading = 90
        let start = SimulationManager.shared.mockCoordinate
        SimulationManager.shared.isSimulationActive = true

        // Pump the run loop long enough for ≥2 ticks.
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))

        let now = SimulationManager.shared.mockCoordinate
        XCTAssertGreaterThan(now.longitude, start.longitude, "must travel east")
        XCTAssertEqual(now.latitude, start.latitude, accuracy: 0.001, "no northward drift")
        let meters = now.longitude - start.longitude > 0
            ? (now.longitude - start.longitude) * 111_320 * cos(start.latitude * .pi / 180)
            : 0
        // 1–3 ticks of 26.8 m.
        XCTAssertGreaterThan(meters, 26.0, "motion not integrating (moved \(meters) m)")
        XCTAssertLessThan(meters, 3 * 26.9, "motion integrating too fast")
    }

    func testZeroSpeedProducesNoMovement() {
        SimulationManager.shared.mockSpeed = 0
        SimulationManager.shared.mockHeading = 45
        let start = SimulationManager.shared.mockCoordinate
        SimulationManager.shared.isSimulationActive = true

        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        let now = SimulationManager.shared.mockCoordinate
        XCTAssertEqual(now.latitude, start.latitude, accuracy: 1e-9)
        XCTAssertEqual(now.longitude, start.longitude, accuracy: 1e-9)
        // Broadcasts still flow (speed 0 fixes are valid engine input).
        XCTAssertFalse(broadcastLocations.isEmpty, "zero-speed fixes must still broadcast")
    }

    // MARK: - Lifecycle

    func testInactiveSimulationBroadcastsNothing() {
        SimulationManager.shared.mockSpeed = 50
        // Not activated.
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        XCTAssertTrue(broadcastLocations.isEmpty, "inactive simulator must not broadcast")
    }

    func testDeactivationStopsTheBroadcastStream() {
        SimulationManager.shared.mockSpeed = 50
        SimulationManager.shared.isSimulationActive = true
        waitBroadcasts(count: 1, timeout: 3)
        XCTAssertTrue(broadcastLocations.contains { $0.timestamp > Date().addingTimeInterval(-3) })

        SimulationManager.shared.isSimulationActive = false
        let countAtStop = broadcastLocations.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        XCTAssertEqual(broadcastLocations.count, countAtStop, "broadcasts continued after deactivation")
    }

    func testReactivationResumesBroadcasts() {
        SimulationManager.shared.mockSpeed = 50
        SimulationManager.shared.isSimulationActive = true
        waitBroadcasts(count: 1, timeout: 3)
        SimulationManager.shared.isSimulationActive = false
        let quiet = broadcastLocations.count
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(broadcastLocations.count, quiet)

        SimulationManager.shared.isSimulationActive = true
        waitBroadcasts(count: quiet + 1, timeout: 3)
    }

    // MARK: - Road snapping through the data source

    func testRoadSnapPullsMockOntoRouteAndInheritsHeading() {
        let route = FixedRouteSource()
        route.snap = CLLocationCoordinate2D(latitude: 33.4500, longitude: -112.0600)
        route.roadHeading = 137.0
        // Hold a strong reference: dataSource is weak.
        routeRetainer = route
        SimulationManager.shared.dataSource = route

        SimulationManager.shared.mockSpeed = 60
        SimulationManager.shared.mockHeading = 0 // user starts pointing north
        SimulationManager.shared.isSimulationActive = true

        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        XCTAssertGreaterThan(route.calls, 0, "snapping data source never consulted")
        let snapped = SimulationManager.shared.mockCoordinate
        XCTAssertEqual(snapped.latitude, route.snap!.latitude, accuracy: 1e-6, "mock not pulled onto route")
        XCTAssertEqual(snapped.longitude, route.snap!.longitude, accuracy: 1e-6)
        XCTAssertEqual(SimulationManager.shared.mockHeading, 137.0, accuracy: 0.01,
                       "road heading not inherited")
        // And the broadcast itself carries the snapped position.
        if let last = broadcastLocations.last {
            XCTAssertEqual(last.coordinate.latitude, route.snap!.latitude, accuracy: 1e-4)
            XCTAssertEqual(last.course, 137.0, accuracy: 0.01)
        }
    }

    func testNoDataSourceLeavesRawIntegration() {
        SimulationManager.shared.mockSpeed = 60
        SimulationManager.shared.mockHeading = 90
        let start = SimulationManager.shared.mockCoordinate
        SimulationManager.shared.isSimulationActive = true

        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        XCTAssertGreaterThan(SimulationManager.shared.mockCoordinate.longitude, start.longitude,
                             "without a data source the raw integrated motion must apply")
    }

    // MARK: - Multiple observers

    func testAllObserversReceiveTheSameLocationObject() {
        var second: [Notification] = []
        let secondObserver = NotificationCenter.default.addObserver(
            forName: .didUpdateMockLocation, object: nil, queue: nil
        ) { second.append($0) }
        defer { NotificationCenter.default.removeObserver(secondObserver) }

        SimulationManager.shared.mockSpeed = 40
        SimulationManager.shared.isSimulationActive = true
        waitBroadcasts(count: 1, timeout: 3)

        XCTAssertFalse(second.isEmpty)
        let a = broadcastLocations.first
        let b = second.compactMap { $0.object as? CLLocation }.first
        XCTAssertTrue(a === b, "observers must see the identical CLLocation instance")
    }

    // MARK: - Helpers

    private var routeRetainer: AnyObject?

    private func waitBroadcasts(count: Int, timeout: TimeInterval) {
        let exp = expectation(description: "≥\(count) broadcasts")
        // Satisfied lazily once enough notifications have arrived.
        let token = NotificationCenter.default.addObserver(
            forName: .didUpdateMockLocation, object: nil, queue: nil
        ) { _ in
            if self.notifications.count >= count { exp.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        wait(for: [exp], timeout: timeout)
    }
}

// MARK: - Custom GPX simulation + mock-location verification
//
// The Developer panel (Settings → GPS ACCURACY, DEBUG-only) replays the
// bundled TestRoutes.gpx threshold ladder through MockLocationManager, which
// posts on the SAME .didUpdateMockLocation wire as the manual SimulationManager.
// These tests pin the three requirements of the custom-GPX mock system:
//   1. The bundled GPX is present, parses, and carries the designed 25→75 MPH
//      threshold landmarks at their documented indices.
//   2. MockLocationManager bypasses CoreLocation and streams EXACT m/s
//      speeds (GPX replay, seek, and on-demand manual streams) on the shared
//      mock wire — LocationManager forwards them to SpeedEngine untouched.
//   3. The full UI pipeline (SpeedEngine smoothing/deadband → SpeedStatus →
//      AlertEngine warning/over triggers) responds correctly to the speed
//      changes defined in the GPX/mock data.
@MainActor
final class MockLocationGPXThresholdTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!
    private var notifications: [Notification] = []
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set("Imperial", forKey: "measurementSystem")
        notifications = []
        observer = NotificationCenter.default.addObserver(
            forName: .didUpdateMockLocation, object: nil, queue: nil
        ) { [weak self] note in self?.notifications.append(note) }
    }

    override func tearDown() {
        MockLocationManager.shared.stop()
        MockLocationManager.shared.pauseManualStream()
        SimulationManager.shared.isSimulationActive = false
        SimulationManager.shared.mockSpeed = 0
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    private var broadcastLocations: [CLLocation] {
        notifications.compactMap { $0.object as? CLLocation }
    }

    // MARK: 1 — The bundled GPX resource

    func testBundledGPXLoadsFromAppBundle() {
        // Unit tests run in the app host, so the target resource must exist.
        // If XcodeGen drops it (project.yml resources), fail loud like
        // CameraTuningResourceIntegrityTests does.
        XCTAssertNotNil(Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx"),
                        "TestRoutes.gpx missing from the app bundle — check project.yml resources")
    }

    func testBundledGPXParsesWithThresholdLandmarks() {
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()
        XCTAssertNil(mock.lastError)
        XCTAssertEqual(mock.pointCount, 150, "the designed ladder is 150 one-second fixes")
        XCTAssertFalse(mock.routeName.isEmpty, "GPX <name> must carry the route title")
    }

    func testGPXParserReadsExactMetersPerSecondSpeeds() {
        // Parse the raw XML directly to pin the parser's unit contract:
        // GPX <speed> is m/s and must survive parsing UNCHANGED (no mph
        // double-conversion — the broadcast layer posts it as-is).
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Unit Contract</name><trkseg>
            <trkpt lat="33.4484000" lon="-112.0740000"><ele>350</ele><time>2026-09-23T00:00:00Z</time><speed>11.17600</speed></trkpt>
            <trkpt lat="33.4485000" lon="-112.0740000"><ele>350</ele><time>2026-09-23T00:00:01Z</time><speed>33.52800</speed></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let (name, points) = MockLocationManager.parseGPX(xml)
        XCTAssertEqual(name, "Unit Contract")
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].speedMetersPerSecond, 25 * 0.44704, accuracy: 1e-9,
                       "11.176 m/s is exactly 25 mph — parser must keep m/s")
        XCTAssertEqual(points[1].speedMetersPerSecond, 75 * 0.44704, accuracy: 1e-9,
                       "33.528 m/s is exactly 75 mph")
        XCTAssertEqual(points[0].coordinate.latitude, 33.4484000, accuracy: 1e-9)
        XCTAssertEqual(points[0].coordinate.longitude, -112.0740000, accuracy: 1e-9)
    }

    func testGPXLandmarkIndicesCarryDesignedThresholdSpeeds() throws {
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()
        let expectedMps = { (mph: Double) in mph * 0.44704 }
        let point25 = try XCTUnwrap(self.point(at: MockRouteLandmark.mph25Index))
        let point75 = try XCTUnwrap(self.point(at: MockRouteLandmark.mph75Index))
        XCTAssertEqual(point25.speedMetersPerSecond, expectedMps(25), accuracy: 1e-6,
                       "t=25 s must be the exact 25 MPH threshold fix")
        XCTAssertEqual(point75.speedMetersPerSecond, expectedMps(75), accuracy: 1e-6,
                       "t=75 s must be the exact 75 MPH threshold fix")
        XCTAssertEqual(point25.coordinate.latitude, 33.4484, accuracy: 0.01,
                       "the ladder starts at the SimulationManager Phoenix default")
    }

    private func point(at index: Int) -> MockRoutePoint? {
        // The route lives behind the manager; re-parse the bundle copy so
        // this helper stays read-only.
        guard let url = Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let points = MockLocationManager.parseGPX(xml).points
        return points.indices.contains(index) ? points[index] : nil
    }

    // MARK: 2 — CoreLocation bypass + exact-speed streaming

    func testSeekBroadcastsExactLandmarkSpeedImmediately() {
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()

        mock.seek(to: MockRouteLandmark.mph75Index)

        guard let fix = broadcastLocations.last else {
            return XCTFail("seek must broadcast a fix immediately")
        }
        XCTAssertEqual(fix.speed, 75 * 0.44704, accuracy: 1e-6,
                       "the 75 MPH GPX landmark must stream at exactly 75 mph in m/s")
        XCTAssertEqual(fix.horizontalAccuracy, 5.0, accuracy: 0.001,
                       "mock fixes must pass LocationManager/SpeedEngine accuracy gates")
    }

    func testManualExactSpeedStreamBroadcastsExactMetersPerSecond() {
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()

        // On-demand exact speed: 62.5 mph → 27.930875 m/s. No physics, no
        // integration, no smoothing at the mock layer.
        mock.streamSpeed(mph: 62.5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        let fixes = broadcastLocations
        XCTAssertGreaterThanOrEqual(fixes.count, 2,
                                    "streamSpeed must emit immediately AND on the next tick")
        for fix in fixes {
            XCTAssertEqual(fix.speed, 62.5 / 2.23694, accuracy: 1e-9,
                           "every streamed fix carries the exact requested speed")
        }
    }

    func testOneShotSetSpeedBroadcastsSingleExactFix() {
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()

        mock.setSpeed(mph: 40)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(broadcastLocations.count, 1,
                       "setSpeed is a single fix, not a stream")
        // mph→m/s uses the SAME divide-by-2.23694 convention as
        // SimulationManager and GPSFixFactory.
        XCTAssertEqual(broadcastLocations.first?.speed ?? -1, 40 / 2.23694, accuracy: 1e-9)
    }

    func testReplayBroadcastsThroughTheSharedMockWire() {
        // play() must stream successive GPX fixes at ~1 Hz on the SAME
        // notification LocationManager subscribes to.
        let mock = MockLocationManager.shared
        mock.stop()
        mock.loadBundledRoute()
        mock.play()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))

        let fixes = broadcastLocations
        XCTAssertGreaterThanOrEqual(fixes.count, 2, "replay must tick at 1 Hz")
        // Successive ladder speeds increase by exactly 1 mph/s on the ramp:
        // the first two ticks must differ by 0.44704 m/s.
        if fixes.count >= 2 {
            let delta = fixes[1].speed - fixes[0].speed
            XCTAssertEqual(delta, 0.44704, accuracy: 1e-6,
                           "the ladder's 1 mph/s ramp must be visible in consecutive fixes")
        }
    }

    func testMockFixesFlowThroughLocationManagerIntoTheEngine() {
        // End-to-end wire proof: LocationManager in mock mode + recording
        // forwards the broadcast CLLocation into @Published latestLocation.
        let manager = LocationManager()
        manager.isMockMode = true
        manager.startUpdatingLocation()
        defer { manager.stopUpdatingLocation() }

        MockLocationManager.shared.stop()
        MockLocationManager.shared.loadBundledRoute()
        MockLocationManager.shared.seek(to: MockRouteLandmark.mph25Index)
        waitForMainQueueTurn("mock → LocationManager hop")

        XCTAssertNotNil(manager.latestLocation,
                        "LocationManager must forward mock fixes to the engine pipeline")
        XCTAssertEqual(manager.latestLocation?.speed ?? -1, 25 * 0.44704, accuracy: 1e-6)
    }

    // MARK: 3 — Speedometer + warning triggers respond to the ladder

    /// Replays GPX fixes through the real SpeedEngine pipeline (the same
    /// processing the broadcast wire feeds) and asserts the HUD speed and
    /// the warning/over thresholds respond at the designed ladder points.
    /// Fixes use accuracy 150 m so the coordinate-driven speed-limit
    /// resolution stays hermetic; the limit is applied via the manual path
    /// exactly like DriveViewModel's direct lookup.
    private func makeHermeticEngine() -> SpeedEngine {
        SpeedEngine(locationManager: LocationManager())
    }

    private func displayOnlyFix(_ point: MockRoutePoint, secondsOffset: Int) -> CLLocation {
        GPSFixFactory.fix(lat: point.coordinate.latitude,
                          lon: point.coordinate.longitude,
                          speedMph: point.speedMetersPerSecond / 0.44704,
                          course: point.courseDegrees,
                          accuracy: 150,
                          timestamp: Date().addingTimeInterval(Double(secondsOffset)))
    }

    func testSpeedEngineTracksTheGPXLadderWithSmoothing() {
        let engine = makeHermeticEngine()
        engine.applyResolvedLimit(70)
        guard let url = Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("TestRoutes.gpx missing")
        }
        let points = MockLocationManager.parseGPX(xml).points

        // Ramp portion t=0...40: each fix is 1 s after the previous. The
        // engine's normal EMA (factor 0.35 — a 1 mph step is below the
        // 10 mph rapid-change threshold) carries a steady-state ramp lag of
        // (1−0.35)/0.35 ≈ 1.86 mph on the 1 mph/s ladder, so the HUD must
        // land within 0.2 mph of raw-minus-lag. This pins that the
        // speedometer tracks the GPX changes with the documented filter —
        // not that it mirrors raw GPS 1:1 (it never does, by design).
        for (offset, point) in points.prefix(41).enumerated() {
            engine.processLocationForTesting(displayOnlyFix(point, secondsOffset: offset))
        }
        let rawMph40 = points[40].speedMetersPerSecond / 0.44704
        let emaLag = (1.0 - 0.35) / 0.35 // steady-state ramp lag, mph
        XCTAssertEqual(engine.speed, rawMph40 - emaLag, accuracy: 0.2,
                       "HUD speed must track the GPX ramp minus the documented EMA lag at t=40")

        // The 15 s hold at 75 (t=76...90) must converge exactly.
        for (offset, point) in points[76...90].enumerated() {
            engine.processLocationForTesting(displayOnlyFix(point, secondsOffset: 76 + offset))
        }
        assertMph(engine.speed, equals: 75.0,
                  "HUD speed must read 75 after the GPX hold")
        XCTAssertEqual(engine.status, .warning,
                       "75 mph on a 70 limit (+5 buffer) is exactly the warning boundary")
    }

    func testWarningAndOverTriggersFireAcrossTheGPXThresholds() {
        let engine = makeHermeticEngine()
        engine.applyResolvedLimit(70) // +5 default buffer → threshold 75

        var sawWarningBeforeOver = false
        var overIndex: Int?
        var safeAgain = false

        guard let url = Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("TestRoutes.gpx missing")
        }
        let points = MockLocationManager.parseGPX(xml).points
        for (idx, point) in points.enumerated() {
            engine.processLocationForTesting(displayOnlyFix(point, secondsOffset: idx))
            switch engine.status {
            case .warning where overIndex == nil:
                sawWarningBeforeOver = true
            case .over:
                if overIndex == nil { overIndex = idx }
            case .safe where overIndex != nil:
                safeAgain = true
            default:
                break
            }
        }

        // Threshold 75: warning band [74, 75], over strictly above 75. The
        // 15 s hold AT 75 converges to the threshold asymptotically from
        // below (warning), so .over first fires when the 76 mph fix lands
        // at t=91 (within the EMA's one-tick response).
        XCTAssertNotNil(overIndex, "the ladder must cross into .over above 75 mph")
        if let overIndex {
            XCTAssertGreaterThanOrEqual(overIndex, 76,
                                        "no overspeed while the ladder holds at exactly the threshold")
            XCTAssertLessThanOrEqual(overIndex, 92,
                                     "overspeed must trigger within ~2 s of crossing above 75")
        }
        XCTAssertTrue(sawWarningBeforeOver,
                      "the warning band must be crossed before .over")
        XCTAssertTrue(safeAgain,
                      "the ladder's 45 mph tail must return the status to .safe")
        XCTAssertEqual(engine.status, .safe)
    }

    func testAlertEngineStartsMonitoringWhenGPXHoldExceedsThreshold() {
        // Full warning-trigger verification: drive the ladder through a real
        // SpeedEngine + AlertEngine pair. The 80 mph hold (t=96...105) is 5
        // mph over a 70 limit with the +5 buffer → monitoring must engage.
        // Audio is enabled so an episode actually starts (with BOTH channels
        // off, AlertEngine deliberately never monitors — pinned behavior);
        // haptics stay off to keep Core Haptics out of the test host.
        UserDefaults.standard.set(true, forKey: "audioAlertsEnabled")
        UserDefaults.standard.set(false, forKey: "hapticAlertsEnabled")
        let speedEngine = makeHermeticEngine()
        let alertEngine = AlertEngine(speedEngine: speedEngine)
        speedEngine.applyResolvedLimit(70)

        guard let url = Bundle.main.url(forResource: "TestRoutes", withExtension: "gpx"),
              let xml = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("TestRoutes.gpx missing")
        }
        let points = MockLocationManager.parseGPX(xml).points
        for (idx, point) in points.prefix(101).enumerated() {
            speedEngine.processLocationForTesting(displayOnlyFix(point, secondsOffset: idx))
        }
        waitForMainQueueTurn("status propagation")

        XCTAssertEqual(speedEngine.status, .over, "80 mph vs threshold 75 must be .over")
        XCTAssertEqual(alertEngine.consecutiveSeconds, 1,
                       "the over-limit episode must start immediately at the hold")

        // Feed the 45 mph safe soak: the episode must tear down.
        for (idx, point) in points[106...].enumerated() {
            speedEngine.processLocationForTesting(displayOnlyFix(point, secondsOffset: 106 + idx))
        }
        waitForMainQueueTurn("status propagation")
        XCTAssertEqual(alertEngine.consecutiveSeconds, 0,
                       "the 45 mph tail must end the over-limit episode")
    }
}
