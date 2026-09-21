import XCTest
@testable import SmartSpeedCompanion

/// Model-layer integrity: NamedLocation + VehicleProfile are SwiftData @Model
/// classes (favorites and vehicle setup). These tests verify real
/// constructor semantics, mutation behavior, and the reference-data invariants
/// the VehicleIcon catalog must satisfy. Pure local data, no network.
final class NamedLocationModelTests: XCTestCase {

    // MARK: - NamedLocation construction

    func testNamedLocationInitialization() {
        let loc = NamedLocation(name: "Home", latitude: 37.3349,
                                longitude: -122.0090, address: "1 Infinite Loop")
        XCTAssertEqual(loc.name, "Home")
        XCTAssertEqual(loc.latitude, 37.3349, accuracy: 1e-12)
        XCTAssertEqual(loc.longitude, -122.0090, accuracy: 1e-12)
        XCTAssertEqual(loc.address, "1 Infinite Loop")
    }

    func testNamedLocationHasUniqueIDs() {
        // @Attribute(.unique) id — two saved "Home" entries must still be
        // distinct objects with distinct IDs.
        let a = NamedLocation(name: "Home", latitude: 1, longitude: 1, address: nil)
        let b = NamedLocation(name: "Home", latitude: 1, longitude: 1, address: nil)
        XCTAssertNotEqual(a.id, b.id, "ID collision would corrupt SwiftData upserts")
    }

    func testNamedLocationAddressIsOptional() {
        let without = NamedLocation(name: "Trailhead", latitude: 1, longitude: 1, address: nil)
        XCTAssertNil(without.address)
        let with = NamedLocation(name: "Office", latitude: 1, longitude: 1, address: "")
        XCTAssertNotNil(with.address)
    }

    func testNamedLocationUnicodeSurvivesMutation() {
        let loc = NamedLocation(name: "Café ☕ 東京", latitude: 35.6812,
                                longitude: 139.7671, address: nil)
        loc.name = "咖啡 ☕"
        XCTAssertEqual(loc.name, "咖啡 ☕")
    }

    func testNamedLocationCreatedAtIsSane() {
        let loc = NamedLocation(name: "X", latitude: 0, longitude: 0, address: nil)
        let now = Date()
        XCTAssertLessThanOrEqual(loc.createdAt, now.addingTimeInterval(1))
        XCTAssertGreaterThanOrEqual(loc.createdAt, now.addingTimeInterval(-60))
    }

    // MARK: - Extreme coordinates (poles/antimeridian favorites)

    func testNamedLocationExtremeCoordinatesPreserved() {
        // Float64 fidelity matters at the antimeridian: a Float32 slip puts a
        // favorite on the wrong side of the planet and breaks geofencing.
        for (lat, lon) in [(90.0, 0.0), (0.0, 180.0), (-54.8019, -68.3030), (-89.9999, 179.9999)] {
            let loc = NamedLocation(name: "Edge", latitude: lat, longitude: lon, address: nil)
            XCTAssertEqual(loc.latitude, lat, accuracy: 1e-9)
            XCTAssertEqual(loc.longitude, lon, accuracy: 1e-9)
        }
    }

    // MARK: - VehicleProfile construction + defaults

    func testVehicleProfileDefaults() {
        let p = VehicleProfile(name: "Civic")
        XCTAssertEqual(p.name, "Civic")
        XCTAssertFalse(p.isActive, "New profiles must not steal active status")
        XCTAssertEqual(p.userBuffer, 5, "Default buffer drifted from product spec")
        XCTAssertTrue(p.audioAlertsEnabled)
        XCTAssertTrue(p.hapticAlertsEnabled)
        XCTAssertEqual(p.hapticAlertStyle, "strong")
        XCTAssertFalse(p.avoidHighways)
        XCTAssertEqual(p.vehicleIconId, "default_blue")
        XCTAssertEqual(p.measurementSystem, "Imperial")
        XCTAssertEqual(p.totalTrips, 0)
        XCTAssertEqual(p.totalDistanceMiles, 0, accuracy: 1e-9)
        XCTAssertEqual(p.totalDurationSeconds, 0, accuracy: 1e-9)
    }

    func testVehicleProfileExplicitValues() {
        let p = VehicleProfile(name: "Truck", isActive: true, userBuffer: 9,
                               audioAlertsEnabled: false, hapticAlertsEnabled: false,
                               hapticAlertStyle: "subtle", avoidHighways: true,
                               vehicleIconId: "truck_red", measurementSystem: "Metric",
                               totalTrips: 42, totalDistanceMiles: 1234.5,
                               totalDurationSeconds: 98_765)
        XCTAssertEqual(p.userBuffer, 9)
        XCTAssertTrue(p.isActive)
        XCTAssertFalse(p.audioAlertsEnabled)
        XCTAssertEqual(p.vehicleIconId, "truck_red")
        XCTAssertEqual(p.measurementSystem, "Metric")
        XCTAssertEqual(p.totalTrips, 42)
        XCTAssertEqual(p.totalDistanceMiles, 1234.5, accuracy: 1e-9)
    }

    func testVehicleProfileMutationSemantics() {
        // SwiftData models are reference types; in-place edits must stick and
        // be visible through another reference (settings screens rely on it).
        let p = VehicleProfile(name: "Van")
        let alias = p
        p.userBuffer = 12
        XCTAssertEqual(alias.userBuffer, 12, "Reference semantics broken — settings edits would be lost")
    }

    func testVehicleProfileUniqueIDs() {
        let a = VehicleProfile(name: "Same")
        let b = VehicleProfile(name: "Same")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - VehicleIcon reference integrity

    func testVehicleIconCatalogHasDefaultIcon() {
        // VehicleProfile defaults to "default_blue"; the catalog must always
        // contain it or every fresh install renders a missing icon.
        let ids = Set(VehicleIcon.catalog.map { $0.id })
        XCTAssertTrue(ids.contains("default_blue"),
                      "Catalog lost default_blue — fresh installs break")
    }

    func testVehicleIconIdsAreUnique() {
        let ids = VehicleIcon.catalog.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate icon ids break profile lookups")
    }

    func testVehicleIconLookupFallbackAlwaysResolves() {
        // Unknown ids (deleted icons, stale persisted data) must fall back to
        // the default, never crash or return a sentinel.
        let resolved = VehicleIcon.icon(for: "no_such_icon_xyz")
        XCTAssertEqual(resolved.id, "default_blue")
        // Every catalog id must resolve to itself.
        for icon in VehicleIcon.catalog {
            XCTAssertEqual(VehicleIcon.icon(for: icon.id).id, icon.id)
        }
    }

    func testVehicleIconDisplayNamesArePickerReady() {
        for icon in VehicleIcon.catalog {
            XCTAssertFalse(icon.displayName.isEmpty, icon.id)
            XCTAssertLessThan(icon.displayName.count, 30,
                              "\(icon.displayName) overflows the picker cell")
            XCTAssertFalse(icon.systemImageName.isEmpty, icon.id)
        }
    }

    func testVehicleIconTintIsAssignedForWholeCatalog() {
        // Every icon must produce a tint (default branch guarantees it, but a
        // new icon whose case is missing renders inconsistent picker/map).
        for icon in VehicleIcon.catalog {
            let ui = icon.tintColor.uiColor
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertEqual(a, 1, "\(icon.id) tint not fully opaque")
            XCTAssertTrue((0...1).contains(r) && (0...1).contains(g) && (0...1).contains(b))
        }
    }

    func testVehicleIconCodableRoundTrip() throws {
        for icon in VehicleIcon.catalog {
            let data = try JSONEncoder().encode(icon)
            let back = try JSONDecoder().decode(VehicleIcon.self, from: data)
            XCTAssertEqual(back, icon)
        }
    }
}
