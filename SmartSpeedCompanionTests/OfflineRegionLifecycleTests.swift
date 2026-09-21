import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// Offline regions & downloaded limit zones: the JSON-persisted models behind
/// "download this area's limits". Old builds' JSON must keep decoding
/// (optional bbox fields), pinning must survive persistence, and the ID
/// semantics must stay collision-free. Pure local data, zero network.
final class OfflineRegionLifecycleTests: XCTestCase {

    // MARK: - OfflineRegion: legacy center-point path

    func testLegacyRegionInitHasNilBoundingBox() {
        let region = OfflineRegion(label: "Home area", lat: 37.35, lon: -122.02)
        XCTAssertEqual(region.label, "Home area")
        XCTAssertNil(region.northLat, "Legacy path must not fabricate a bbox")
        XCTAssertNil(region.estimatedSizeMB)
        XCTAssertEqual(region.id, "37.35,-122.02")
    }

    // MARK: - OfflineRegion: bounding-box path

    func testBoxedRegionComputesCornersFromSpan() {
        let mkRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.35, longitude: -122.02),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.15))
        let region = OfflineRegion(label: "Bay", region: mkRegion,
                                   estimatedSizeMB: 42.5)
        XCTAssertEqual(region.northLat ?? 0, 37.40, accuracy: 1e-9)
        XCTAssertEqual(region.southLat ?? 0, 37.30, accuracy: 1e-9)
        XCTAssertEqual(region.eastLon ?? 0, -121.945, accuracy: 1e-9)
        XCTAssertEqual(region.westLon ?? 0, -122.095, accuracy: 1e-9)
        XCTAssertEqual(region.estimatedSizeMB ?? 0, 42.5, accuracy: 0.01)
    }

    func testRegionContainsPointInsideBox() {
        let mkRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.35, longitude: -122.02),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.15))
        let region = OfflineRegion(label: "Bay", region: mkRegion, estimatedSizeMB: 1)
        let inside = (lat: 37.35, lon: -122.02)
        XCTAssertTrue(inside.lat >= region.southLat! && inside.lat <= region.northLat!)
        XCTAssertTrue(inside.lon >= region.westLon! && inside.lon <= region.eastLon!)
    }

    // MARK: - JSON persistence round-trips (stored as JSON in UserDefaults)

    func testLegacyRegionJSONRoundTrip() throws {
        let region = OfflineRegion(label: "Legacy", lat: 45.0, lon: 9.0)
        let data = try JSONEncoder().encode(region)
        let back = try JSONDecoder().decode(OfflineRegion.self, from: data)
        XCTAssertEqual(back, region)
    }

    func testBoxedRegionJSONRoundTrip() throws {
        let mkRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.35, longitude: -122.02),
            span: MKCoordinateSpan(latitudeDelta: 0.10, longitudeDelta: 0.15))
        let region = OfflineRegion(label: "Bay", region: mkRegion, estimatedSizeMB: 42.5)
        let data = try JSONEncoder().encode(region)
        let back = try JSONDecoder().decode(OfflineRegion.self, from: data)
        XCTAssertEqual(back, region)
        XCTAssertEqual(back.northLat, region.northLat)
    }

    func testLegacyJSONDecodesInNewSchema() throws {
        // A JSON string an OLD build wrote (no bbox keys) must decode — the
        // bbox fields are optional exactly for this.
        let legacyJSON = #"{"id":"45.0,9.0","label":"Old","lat":45.0,"lon":9.0,"timestamp":600000000.0}"#
        let region = try JSONDecoder().decode(OfflineRegion.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(region.label, "Old")
        XCTAssertNil(region.northLat)
    }

    // MARK: - DownloadedLimitsZone

    private func makeZone(pinned: Bool = false,
                          radiusMiles: Double = 15) -> DownloadedLimitsZone {
        DownloadedLimitsZone(label: "Trip zone", lat: 36.5, lon: -121.9,
                             radiusMiles: radiusMiles, roadCount: 4_200,
                             sizeBytes: 4_200 * 110, isPinned: pinned)
    }

    func testZoneIDIsCompositeKey() {
        let zone = makeZone(radiusMiles: 20)
        XCTAssertEqual(zone.id, "36.5,-121.9,20.0",
                       "ID drift breaks list diffing/deletion")
    }

    func testZoneIDCollidesAcrossSameAreaDownloads() {
        // Documented behavior: re-downloading the same area+radius replaces
        // the same id (upsert), NOT a duplicate row.
        let a = makeZone(radiusMiles: 15)
        let b = makeZone(radiusMiles: 15)
        XCTAssertEqual(a.id, b.id)
    }

    func testZonePinnedFlagSurvivesJSONRoundTrip() throws {
        var zone = makeZone(pinned: true)
        let data = try JSONEncoder().encode(zone)
        let back = try JSONDecoder().decode(DownloadedLimitsZone.self, from: data)
        XCTAssertTrue(back.isPinned, "Pinning lost across persistence — TTL would reap a user's pinned zone")
        zone.isPinned = false
        let data2 = try JSONEncoder().encode(zone)
        let back2 = try JSONDecoder().decode(DownloadedLimitsZone.self, from: data2)
        XCTAssertFalse(back2.isPinned)
    }

    func testZoneRoadCountAndSizeRoundTrip() throws {
        let zone = makeZone()
        let data = try JSONEncoder().encode(zone)
        let back = try JSONDecoder().decode(DownloadedLimitsZone.self, from: data)
        XCTAssertEqual(back.roadCount, 4_200)
        XCTAssertEqual(back.sizeBytes, 4_200 * 110)
    }

    func testZoneRadiusWithinSliderBounds() {
        // The picker slider clamps to 10...50 miles; the model must carry
        // the clamped values without loss.
        for r in [10.0, 25.5, 50.0] {
            XCTAssertEqual(makeZone(radiusMiles: r).radiusMiles, r, accuracy: 1e-9)
        }
    }

    func testZoneUnicodeLabelSurvivesRoundTrip() throws {
        let zone = DownloadedLimitsZone(label: "Àgoady 山地 reserve", lat: 0, lon: 0,
                                        radiusMiles: 10, roadCount: 1,
                                        sizeBytes: 110, isPinned: false)
        let data = try JSONEncoder().encode(zone)
        let back = try JSONDecoder().decode(DownloadedLimitsZone.self, from: data)
        XCTAssertEqual(back.label, "Àgoady 山地 reserve")
    }

    func testBulkZoneListRoundTrip() throws {
        let zones = (0..<50).map {
            DownloadedLimitsZone(label: "Zone \($0)", lat: Double($0) - 25,
                                 lon: Double($0) - 45, radiusMiles: 10,
                                 roadCount: $0 * 100, sizeBytes: Int64($0 * 11_000),
                                 isPinned: $0 % 2 == 0)
        }
        let data = try JSONEncoder().encode(zones)
        let back = try JSONDecoder().decode([DownloadedLimitsZone].self, from: data)
        XCTAssertEqual(back.count, 50)
        XCTAssertEqual(back.filter { $0.isPinned }.count, 25)
    }

    // MARK: - Pinned rows vs cache TTL (SQLite side of the contract)

    func testPinnedCacheRowsExplicitlyDeletable() {
        let cache = HERELocalBatchCache.shared
        let center = CLLocationCoordinate2D(latitude: -33.95001, longitude: 18.46001)
        cache.deleteZone(center: center, radiusMeters: 1_500)
        cache.store(roads: [CachedRoad(roadName: "Pinned Rd", direction: "E",
                                       speedLimitMph: 50,
                                       latitude: center.latitude,
                                       longitude: center.longitude,
                                       source: "here", pinned: true)])
        XCTAssertTrue(cache.isAreaCached(coordinate: center))
        cache.deleteZone(center: center, radiusMeters: 1_500)
        XCTAssertFalse(cache.isAreaCached(coordinate: center),
                       "Explicit zone deletion must still remove pinned rows")
    }
}
