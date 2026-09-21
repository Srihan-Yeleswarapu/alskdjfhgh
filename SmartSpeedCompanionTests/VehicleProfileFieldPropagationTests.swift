import XCTest
import SwiftData
@testable import SmartSpeedCompanion

/// VehicleProfile is the SwiftData model behind per-vehicle alert behavior:
/// buffer, audio/haptic toggles, haptic style, units, icon, and lifetime
/// stats. When a user switches profiles mid-fleet, every one of those fields
/// must arrive exactly as saved for THAT profile — cross-profile bleed is the
/// bug class these tests hunt (a shared static, a forgotten copy, a missing
/// field in Codable/Equal conformance, etc.). Persistence runs through a
/// real in-memory SwiftData container; no stubs.
final class VehicleProfileFieldPropagationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(
            for: VehicleProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func makeProfile(
        name: String,
        buffer: Int,
        audio: Bool,
        haptic: Bool,
        style: String,
        avoid: Bool,
        icon: String,
        units: String
    ) -> VehicleProfile {
        let p = VehicleProfile(name: name)
        p.userBuffer = buffer
        p.audioAlertsEnabled = audio
        p.hapticAlertsEnabled = haptic
        p.hapticAlertStyle = style
        p.avoidHighways = avoid
        p.vehicleIconId = icon
        p.measurementSystem = units
        context.insert(p)
        return p
    }

    private func saveAndReload() {
        try! context.save()
        context.reset()
    }

    // MARK: - Round-trip of every driving field

    func testEveryDrivingFieldSurvivesPersistence() {
        makeProfile(name: "Work Truck", buffer: 8, audio: false, haptic: true,
                    style: "pulse", avoid: true, icon: "truck", units: "Metric")
        saveAndReload()

        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched.count, 1)
        let p = fetched[0]
        XCTAssertEqual(p.name, "Work Truck")
        XCTAssertEqual(p.userBuffer, 8)
        XCTAssertFalse(p.audioAlertsEnabled)
        XCTAssertTrue(p.hapticAlertsEnabled)
        XCTAssertEqual(p.hapticAlertStyle, "pulse")
        XCTAssertTrue(p.avoidHighways)
        XCTAssertEqual(p.vehicleIconId, "truck")
        XCTAssertEqual(p.measurementSystem, "Metric")
    }

    func testTwoProfilesNeverShareFieldState() {
        makeProfile(name: "Calm", buffer: 2, audio: true, haptic: false,
                    style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        makeProfile(name: "Alert", buffer: 9, audio: false, haptic: true,
                    style: "heavy", avoid: true, icon: "truck", units: "Metric")
        saveAndReload()

        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>()).sorted { $0.name < $1.name }
        XCTAssertEqual(fetched.count, 2)
        let calm = fetched[0], alert = fetched[1]
        // The bleed assertion: each profile keeps its own values.
        XCTAssertEqual(calm.userBuffer, 2)
        XCTAssertEqual(alert.userBuffer, 9)
        XCTAssertTrue(calm.audioAlertsEnabled)
        XCTAssertFalse(alert.audioAlertsEnabled)
        XCTAssertEqual(calm.hapticAlertStyle, "rigid")
        XCTAssertEqual(alert.hapticAlertStyle, "heavy")
        XCTAssertEqual(calm.measurementSystem, "Imperial")
        XCTAssertEqual(alert.measurementSystem, "Metric")
    }

    func testEditingOneProfileLeavesTheOtherIntact() {
        let a = makeProfile(name: "A", buffer: 3, audio: true, haptic: true,
                            style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        _ = makeProfile(name: "B", buffer: 7, audio: true, haptic: true,
                        style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        try! context.save()

        a.userBuffer = 4
        try! context.save()
        context.reset()

        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>()).sorted { $0.name < $1.name }
        XCTAssertEqual(fetched[0].userBuffer, 4, "edited profile must persist its new value")
        XCTAssertEqual(fetched[1].userBuffer, 7, "sibling profile must be untouched")
    }

    // MARK: - Stats fields

    func testLifetimeStatsSurvivePersistence() {
        let p = makeProfile(name: "Stats", buffer: 5, audio: true, haptic: true,
                            style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        p.totalTrips = 42
        p.totalDistanceMiles = 1_234.5
        p.totalDurationSeconds = 98_765
        saveAndReload()

        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched[0].totalTrips, 42)
        XCTAssertEqual(fetched[0].totalDistanceMiles, 1_234.5, accuracy: 0.001)
        XCTAssertEqual(fetched[0].totalDurationSeconds, 98_765, accuracy: 0.001)
    }

    // MARK: - Value-domain sanity

    func testNegativeBufferPersistsWithoutError() {
        // The engine clamps at read time; persistence itself must not blow up
        // on a hostile slider state (-1 is reachable through direct set).
        let p = makeProfile(name: "Neg", buffer: -1, audio: true, haptic: true,
                            style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        try! context.save()
        context.reset()
        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched[0].userBuffer, -1, "persistence stores what was written; clamping is the engine's job")
        XCTAssertEqual(p.userBuffer, -1)
    }

    func testExtremeButRealisticFieldValues() {
        // Buffer 10 (max slider), 0 stats (new profile): legal states that
        // must persist without loss.
        let p = makeProfile(name: "Max", buffer: 10, audio: true, haptic: true,
                            style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        p.totalTrips = 0
        p.totalDistanceMiles = 0
        saveAndReload()
        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched[0].userBuffer, 10)
        XCTAssertEqual(fetched[0].totalTrips, 0)
    }

    // MARK: - isActive semantics

    func testMultipleProfilesCanPersistAndDistinctnessHolds() {
        // Even if the app enforces a single active profile at the UI layer,
        // the model must not silently merge or drop distinct instances.
        let profiles = (0..<5).map { i in
            makeProfile(name: "Fleet \(i)", buffer: i, audio: true, haptic: true,
                        style: "rigid", avoid: false, icon: "sedan", units: "Imperial")
        }
        try! context.save()
        context.reset()

        let fetched = try! context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched.count, 5)
        XCTAssertEqual(Set(fetched.map(\.id)).count, 5, "each profile must keep a unique id")
        for (i, p) in fetched.sorted(by: { $0.name < $1.name }).enumerated() {
            XCTAssertEqual(p.userBuffer, i)
        }
        // All local references still alive and distinct:
        XCTAssertEqual(Set(profiles.map(\.id)).count, 5)
    }
}
