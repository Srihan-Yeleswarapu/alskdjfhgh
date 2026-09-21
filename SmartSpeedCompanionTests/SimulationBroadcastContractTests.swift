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
            XCTAssertEqual(last.coordinate.course, 137.0, accuracy: 0.01)
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
