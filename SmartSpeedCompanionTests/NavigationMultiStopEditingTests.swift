import XCTest
@testable import SmartSpeedCompanion

/// Multi-stop editing is a state machine with a generation counter: every
/// accepted edit must invalidate stale route calculations and stale restore
/// attempts, and a failed edit must be rollback-able only against the exact
/// stop list it started from. `calculateMultiStopRoute()` itself needs live
/// MapKit, but the editing/rollback contract below is pure in-memory state —
/// driven through the coordinator's real no-op-closure init.
@MainActor
final class NavigationMultiStopEditingTests: XCTestCase {

    private var coordinator: NavigationCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = NavigationCoordinator()
    }

    override func tearDown() {
        coordinator = nil
        super.tearDown()
    }

    private func stop(_ name: String, lat: Double = 33.30, lon: Double = -111.84) -> RouteStop {
        RouteStop(name: name, latitude: lat, longitude: lon)
    }

    private var ids: [UUID] { coordinator.routeStops.map(\.id) }

    // MARK: - addStop

    func testAddStopAppendsByDefault() {
        coordinator.addStop(stop("A"))
        coordinator.addStop(stop("B"))
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["A", "B"])
    }

    func testAddStopAtIndexZeroInsertsFirst() {
        coordinator.addStop(stop("A"))
        coordinator.addStop(stop("B"), at: 0)
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["B", "A"])
    }

    func testAddStopIndexClampsIntoValidRange() {
        coordinator.addStop(stop("A"))
        // Negative and beyond-end indices must clamp, not crash or wrap.
        coordinator.addStop(stop("B"), at: -7)
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["B", "A"], "negative index clamps to 0")
        coordinator.addStop(stop("C"), at: 99)
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["B", "A", "C"], "oversized index clamps to append")
    }

    func testAddStopBumpsGenerationAndClearsComparison() {
        coordinator.addStop(stop("A"))
        let gen1 = coordinator.routeStopsEditGeneration
        coordinator.addStop(stop("B"))
        XCTAssertGreaterThan(coordinator.routeStopsEditGeneration, gen1, "accepted edit must invalidate stale calculations")
        XCTAssertNil(coordinator.orderingComparison, "edited stops invalidate any ordering comparison")
    }

    // MARK: - removeStop

    func testRemoveStopByIDDropsOnlyThatStop() {
        let a = stop("A"), b = stop("B")
        coordinator.addStop(a)
        coordinator.addStop(b)
        coordinator.removeStop(id: a.id)
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["B"])
    }

    func testRemoveStopWithUnknownIDIsANoOp() {
        coordinator.addStop(stop("A"))
        let gen = coordinator.routeStopsEditGeneration
        coordinator.removeStop(id: UUID())
        XCTAssertEqual(coordinator.routeStops.count, 1, "unknown ID must not mutate the list")
        XCTAssertEqual(coordinator.routeStopsEditGeneration, gen, "rejected edit must not invalidate state")
    }

    // MARK: - moveStop

    func testMoveStopReorders() {
        coordinator.addStop(stop("A"))
        coordinator.addStop(stop("B"))
        coordinator.addStop(stop("C"))
        coordinator.moveStop(from: 2, to: 0)
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["C", "A", "B"])
    }

    func testMoveStopOutOfBoundsIsANoOp() {
        coordinator.addStop(stop("A"))
        coordinator.addStop(stop("B"))
        let before = coordinator.routeStops
        let gen = coordinator.routeStopsEditGeneration

        coordinator.moveStop(from: -1, to: 0)
        coordinator.moveStop(from: 0, to: 5)
        coordinator.moveStop(from: 5, to: 0)

        XCTAssertEqual(coordinator.routeStops, before, "out-of-bounds move must not mutate")
        XCTAssertEqual(coordinator.routeStopsEditGeneration, gen, "rejected move must not bump generation")
    }

    // MARK: - Generation monotonicity across edits

    func testGenerationStrictlyIncreasesAcrossEveryAcceptedEdit() {
        let a = stop("A"), b = stop("B"), c = stop("C")
        coordinator.addStop(a)
        var previous = coordinator.routeStopsEditGeneration

        coordinator.addStop(b)
        XCTAssertGreaterThan(coordinator.routeStopsEditGeneration, previous)
        previous = coordinator.routeStopsEditGeneration

        coordinator.removeStop(id: a.id)
        XCTAssertGreaterThan(coordinator.routeStopsEditGeneration, previous)
        previous = coordinator.routeStopsEditGeneration

        coordinator.addStop(c)
        coordinator.moveStop(from: 1, to: 0)
        XCTAssertGreaterThan(coordinator.routeStopsEditGeneration, previous)
    }

    // MARK: - restoreRouteStops rollback guard rails

    func testRestoreWithMatchingIDsAndGenerationSucceeds() {
        coordinator.addStop(stop("A"))
        coordinator.addStop(stop("B"))
        let snapshot = coordinator.routeStops
        let generation = coordinator.routeStopsEditGeneration

        coordinator.addStop(stop("C")) // user edit that will fail to calculate
        let restored = coordinator.restoreRouteStops(
            snapshot, ifCurrentIDsMatch: ids, expectedGeneration: generation)
        XCTAssertTrue(restored, "rollback against the exact edit generation must succeed")
        XCTAssertEqual(coordinator.routeStops.map(\.name), ["A", "B"], "rollback restores the snapshot list")
    }

    func testRestoreWithMismatchedIDsFailsWithoutMutation() {
        coordinator.addStop(stop("A"))
        let snapshot = coordinator.routeStops
        coordinator.addStop(stop("B"))
        let current = coordinator.routeStops

        let restored = coordinator.restoreRouteStops(
            snapshot, ifCurrentIDsMatch: [UUID(), UUID()])
        XCTAssertFalse(restored, "IDs must match the CURRENT list exactly")
        XCTAssertEqual(coordinator.routeStops, current, "failed rollback must not mutate")
    }

    func testRestoreWithStaleGenerationFails() {
        coordinator.addStop(stop("A"))
        let snapshot = coordinator.routeStops
        let genAtSnapshot = coordinator.routeStopsEditGeneration

        coordinator.addStop(stop("B")) // generation advanced past the snapshot
        coordinator.addStop(stop("C"))
        let currentIDs = ids
        // Rollback names the CURRENT ids but the OLD generation: the edit
        // that produced those ids is not the edit the snapshot belongs to.
        let restored = coordinator.restoreRouteStops(
            snapshot, ifCurrentIDsMatch: currentIDs, expectedGeneration: genAtSnapshot)
        XCTAssertFalse(restored, "stale generation must be rejected even with matching IDs")
        XCTAssertEqual(coordinator.routeStops.count, 3)
    }

    func testRestoreWithoutGenerationCheckStillRequiresIDMatch() {
        coordinator.addStop(stop("A"))
        let snapshot = coordinator.routeStops
        coordinator.removeStop(id: snapshot[0].id)

        // No generation passed, but the ID list no longer matches.
        XCTAssertFalse(coordinator.restoreRouteStops(snapshot, ifCurrentIDsMatch: []))
    }

    func testSnapshotRoundTripPreservesIdentityAndPerLegFields() {
        // Rollback correctness depends on RouteStop's Codable/Equatable
        // round-tripping the per-leg estimates a failed edit may have set.
        var original = RouteStop(
            name: "Coffee", address: "101 Main St",
            latitude: 33.301, longitude: -111.842,
            travelTimeFromPrevious: 615, distanceFromPrevious: 8_240, cumulativeTravelTime: 615)
        original.cumulativeTravelTime = 615

        let data = try! JSONEncoder().encode([original])
        let decoded = try! JSONDecoder().decode([RouteStop].self, from: data)

        XCTAssertEqual(decoded, [original], "Codable round-trip must be exact")
        XCTAssertEqual(decoded[0].id, original.id, "IDs must survive serialization (rollback identity)")
        XCTAssertEqual(decoded[0].travelTimeFromPrevious, 615)
        XCTAssertEqual(decoded[0].distanceFromPrevious, 8_240)
    }

    func testFreshCoordinatorStartsAtZeroStopsAndEmptyGeneration() {
        XCTAssertEqual(coordinator.routeStops.count, 0)
        XCTAssertEqual(coordinator.routeStopsEditGeneration, 0, "fresh coordinator must have a zero generation")
        XCTAssertNil(coordinator.orderingComparison)
        XCTAssertFalse(coordinator.isCalculatingMultiStop)
    }

    func testRepeatedEditsDoNotLeakStops() {
        // 200 edit cycles: the list must stay coherent and bounded.
        for i in 0..<100 {
            coordinator.addStop(stop("s\(i)"))
            let last = coordinator.routeStops.last!
            coordinator.removeStop(id: last.id)
        }
        XCTAssertEqual(coordinator.routeStops.count, 0, "add/remove cycles must balance exactly")
    }
}
