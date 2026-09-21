import XCTest
import SwiftData
@testable import SmartSpeedCompanion

/// Profile models: SpeedAlertProfile's per-road-type buffer dispatch,
/// VehicleProfile's settings mirror, and the VehicleIcon catalog that the
/// map renderer + picker both consume. A broken profile model silently
/// reverts user settings (TestFlight b640) — these are the guards.
@MainActor
final class SpeedAlertProfileRoadTypeTests: XCTestCase {

    // MARK: - SpeedAlertProfile road-type dispatch

    func testBufferDispatchForAllRoadTypes() {
        let profile = SpeedAlertProfile(
            name: "Test",
            highwayBuffer: 8, residentialBuffer: 3, schoolZoneBuffer: 0,
            workZoneBuffer: 1, arterialBuffer: 5, defaultBuffer: 6
        )
        XCTAssertEqual(profile.buffer(for: "highway"), 8)
        XCTAssertEqual(profile.buffer(for: "residential"), 3)
        XCTAssertEqual(profile.buffer(for: "schoolZone"), 0)
        XCTAssertEqual(profile.buffer(for: "workZone"), 1)
        XCTAssertEqual(profile.buffer(for: "arterial"), 5)
    }

    func testBufferDispatchIsCaseInsensitive() {
        let profile = SpeedAlertProfile(name: "Test", highwayBuffer: 8)
        XCTAssertEqual(profile.buffer(for: "HIGHWAY"), 8)
        XCTAssertEqual(profile.buffer(for: "Highway"), 8)
        XCTAssertEqual(profile.buffer(for: "SchoolZone"), 0)
    }

    func testUnknownRoadTypeFallsBackToDefault() {
        let profile = SpeedAlertProfile(name: "Test", defaultBuffer: 6)
        XCTAssertEqual(profile.buffer(for: "parking_lot"), 6)
        XCTAssertEqual(profile.buffer(for: ""), 6)
        XCTAssertEqual(profile.buffer(for: "driveway"), 6)
    }

    func testProfileDefaultsMatchSettingsDefaults() {
        let profile = SpeedAlertProfile(name: "Defaults")
        XCTAssertEqual(profile.highwayBuffer, 5)
        XCTAssertEqual(profile.residentialBuffer, 3)
        XCTAssertEqual(profile.schoolZoneBuffer, 0, "School zones: zero tolerance by default")
        XCTAssertEqual(profile.workZoneBuffer, 0, "Work zones: zero tolerance by default")
        XCTAssertEqual(profile.arterialBuffer, 5)
        XCTAssertEqual(profile.defaultBuffer, 5)
    }

    func testProfileUniqueIds() {
        let a = SpeedAlertProfile(name: "A")
        let b = SpeedAlertProfile(name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - VehicleProfile model

    func testVehicleProfileDefaults() {
        let profile = VehicleProfile(name: "Commuter")
        XCTAssertEqual(profile.userBuffer, 5)
        XCTAssertTrue(profile.audioAlertsEnabled)
        XCTAssertTrue(profile.hapticAlertsEnabled)
        XCTAssertEqual(profile.hapticAlertStyle, "strong")
        XCTAssertFalse(profile.avoidHighways)
        XCTAssertEqual(profile.vehicleIconId, "default_blue")
        XCTAssertEqual(profile.measurementSystem, "Imperial")
        XCTAssertEqual(profile.totalTrips, 0)
        XCTAssertEqual(profile.totalDistanceMiles, 0, accuracy: 1e-9)
        XCTAssertEqual(profile.totalDurationSeconds, 0, accuracy: 1e-9)
    }

    func testVehicleProfileStatsAccumulate() {
        let profile = VehicleProfile(name: "Truck")
        profile.totalTrips += 1
        profile.totalDistanceMiles += 42.5
        profile.totalDurationSeconds += 3600
        XCTAssertEqual(profile.totalTrips, 1)
        XCTAssertEqual(profile.totalDistanceMiles, 42.5, accuracy: 1e-9)
        XCTAssertEqual(profile.totalDurationSeconds, 3600, accuracy: 1e-9)
    }

    func testMultipleProfilesAreIndependent() throws {
        let container = try ModelContainer(
            for: VehicleProfile.self, DriveSession.self, NamedLocation.self, SpeedAlertProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let a = VehicleProfile(name: "A", userBuffer: 2)
        let b = VehicleProfile(name: "B", userBuffer: 9, measurementSystem: "Metric")
        context.insert(a)
        context.insert(b)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<VehicleProfile>())
        XCTAssertEqual(fetched.count, 2)
        let buffers = Dictionary(uniqueKeysWithValues: fetched.map { ($0.name, $0.userBuffer) })
        XCTAssertEqual(buffers["A"], 2)
        XCTAssertEqual(buffers["B"], 9)
        let systems = Dictionary(uniqueKeysWithValues: fetched.map { ($0.name, $0.measurementSystem) })
        XCTAssertEqual(systems["B"], "Metric")
    }

    // MARK: - VehicleIcon catalog

    func testCatalogHasDefaultFirst() {
        XCTAssertEqual(VehicleIcon.catalog.first?.id, "default_blue",
                       "Existing installs migrate to the first catalog entry — keep it stable")
    }

    func testCatalogIdsAreUnique() {
        let ids = VehicleIcon.catalog.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate icon ids break picker selection")
    }

    func testEveryCatalogIconResolvesAndFallsBack() {
        for icon in VehicleIcon.catalog {
            XCTAssertEqual(VehicleIcon.icon(for: icon.id), icon)
        }
        XCTAssertEqual(VehicleIcon.icon(for: "nonexistent-garbage"),
                       VehicleIcon.catalog[0],
                       "Unknown ids must resolve to the default, never nil/crash")
    }

    func testEveryIconHasDisplayNameAndSymbol() {
        for icon in VehicleIcon.catalog {
            XCTAssertFalse(icon.displayName.isEmpty, "\(icon.id) missing display name")
            XCTAssertFalse(icon.systemImageName.isEmpty, "\(icon.id) missing SF Symbol")
        }
    }

    func testIconTintCoversWholeCatalog() {
        for icon in VehicleIcon.catalog {
            // Accessing tintColor/uiColor exercises the switch — an
            // uncovered case would trap here in debug.
            _ = icon.tintColor
            _ = icon.tintColor.uiColor
        }
    }

    func testDefaultIconStaysCyan() {
        XCTAssertEqual(VehicleIcon.icon(for: "default_blue").tintColor.uiColor,
                       VehicleIconTint.cyan.uiColor,
                       "Default icon tint drift changes every existing install's map marker")
    }

    func testCatalogIsFreeTier() {
        // The premium flag is reserved for the future ad layer; today
        // everything must be unlocked so the picker shows no locks.
        XCTAssertTrue(VehicleIcon.catalog.allSatisfy { !$0.isPremium })
    }
}
