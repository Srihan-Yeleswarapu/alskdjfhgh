import XCTest
import MapKit
@testable import SmartSpeedCompanion

/// Offline limits + map regions: the estimate UX (size/time labels the
/// confirmation sheet shows), the zone model the list persists, the legacy
/// maxspeed parser (isolated research path), and OfflineRegion's bounding
/// boxes.
final class OfflineLimitsAndZonesTests: XCTestCase {

    // MARK: - Estimate labels

    func testSizeLabelsAcrossMagnitudes() {
        func label(_ bytes: Int64) -> String {
            OfflineLimitsEstimate(roadCount: 1, sizeBytes: bytes,
                                  estimatedSeconds: 1, isReal: false).sizeLabel
        }
        XCTAssertEqual(label(500), "500 B")
        XCTAssertEqual(label(2048), "2 kB")
        XCTAssertEqual(label(5 * 1024 * 1024), "5.0 MB")
    }

    func testTimeLabelsAcrossDurations() {
        func label(_ seconds: Int) -> String {
            OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1,
                                  estimatedSeconds: seconds, isReal: false).timeLabel
        }
        XCTAssertEqual(label(30), "~30 s")
        XCTAssertEqual(label(90), "~1 min 30 s")
        XCTAssertEqual(label(120), "~2 min")
        XCTAssertEqual(label(0), "~1 s", "Zero must clamp up so the sheet never says '~0 s'")
    }

    func testEstimateIsMarkedInexact() {
        let estimate = OfflineLimitsDownloader().heuristicEstimate(radiusMiles: 10)
        XCTAssertFalse(estimate.isReal,
                       "The heuristic estimate must never claim measured certainty")
    }

    // MARK: - Heuristic estimate scaling

    func testHeuristicScalesWithArea() {
        let small = OfflineLimitsDownloader().heuristicEstimate(radiusMiles: 5)
        let large = OfflineLimitsDownloader().heuristicEstimate(radiusMiles: 20)
        XCTAssertGreaterThan(large.roadCount, small.roadCount)
        // πr² scaling: 4× radius → 16× roads.
        XCTAssertEqual(Double(large.roadCount) / Double(small.roadCount), 16.0, accuracy: 0.1)
    }

    func testHeuristicNegativeRadiusClamps() {
        let estimate = OfflineLimitsDownloader().heuristicEstimate(radiusMiles: -5)
        XCTAssertEqual(estimate.roadCount, 0, "Negative radius must clamp to zero roads")
    }

    func testEstimateCenterIsIrrelevant() async {
        // The compatibility estimate ignores the center by contract.
        let a = await OfflineLimitsDownloader.shared.estimate(
            center: CLLocationCoordinate2D(latitude: 33.3, longitude: -111.8), radiusMiles: 10)
        let b = await OfflineLimitsDownloader.shared.estimate(
            center: CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0), radiusMiles: 10)
        XCTAssertEqual(a, b)
    }

    // MARK: - Legacy maxspeed parser (isolated Overpass path)

    func testMphFromMaxspeedPlainNumbers() {
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "45"), 45)
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "65 mph"), 65)
    }

    func testMphFromMaxspeedKmhConversion() {
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "100 km/h"), 62,
                       "100 km/h ≈ 62.1 mph")
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "50 kmh"), 31)
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "80 kph"), 50)
    }

    func testMphFromMaxspeedRejectsGarbage() {
        XCTAssertNil(OfflineLimitsDownloader.mph(fromMaxspeed: "none"))
        XCTAssertNil(OfflineLimitsDownloader.mph(fromMaxspeed: "signals"))
        XCTAssertNil(OfflineLimitsDownloader.mph(fromMaxspeed: "0"))
        XCTAssertNil(OfflineLimitsDownloader.mph(fromMaxspeed: "300"), "Above 200 is bogus")
        XCTAssertNil(OfflineLimitsDownloader.mph(fromMaxspeed: ""))
    }

    func testMphFromMaxspeedStopsAtFirstToken() {
        // "25 mph;30" must parse 25, not concatenate digits.
        XCTAssertEqual(OfflineLimitsDownloader.mph(fromMaxspeed: "25 mph;30"), 25)
    }

    // MARK: - DownloadedLimitsZone model

    func testZoneIdentityComposesLatLonRadius() {
        let zone = DownloadedLimitsZone(label: "Home", lat: 33.3, lon: -111.8,
                                        radiusMiles: 15, roadCount: 1200,
                                        sizeBytes: 158_400, isPinned: false)
        XCTAssertEqual(zone.id, "33.3,-111.8,15.0")
    }

    func testZonePinToggleMutates() {
        var zone = DownloadedLimitsZone(label: "Z", lat: 33.3, lon: -111.8,
                                        radiusMiles: 10, roadCount: 100,
                                        sizeBytes: 11_000, isPinned: false)
        zone.isPinned = true
        XCTAssertTrue(zone.isPinned)
    }

    func testZonesCodableRoundTrip() throws {
        let zone = DownloadedLimitsZone(label: "Commute", lat: 33.35, lon: -111.9,
                                        radiusMiles: 22.5, roadCount: 4400,
                                        sizeBytes: 581_000, isPinned: true,
                                        downloadedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode([zone])
        let decoded = try JSONDecoder().decode([DownloadedLimitsZone].self, from: data)
        XCTAssertEqual(decoded, [zone])
    }

    // MARK: - OfflineRegion bounding boxes

    func testLegacyRegionDecodesWithoutBBox() throws {
        // JSON from builds before the bbox fields must still decode.
        let legacy = """
        {"id":"33.3,-111.8","label":"Old","lat":33.3,"lon":-111.8,
         "timestamp":1700000000}
        """
        let region = try JSONDecoder().decode(OfflineRegion.self, from: Data(legacy.utf8))
        XCTAssertEqual(region.label, "Old")
        XCTAssertNil(region.northLat)
        XCTAssertNil(region.estimatedSizeMB)
    }

    func testRegionBoundingBoxConstruction() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.3, longitude: -111.8),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
        )
        let offline = OfflineRegion(label: "Box", region: region, estimatedSizeMB: 42)
        XCTAssertEqual(offline.northLat ?? 0, 33.4, accuracy: 1e-9)
        XCTAssertEqual(offline.southLat ?? 0, 33.2, accuracy: 1e-9)
        XCTAssertEqual(offline.eastLon ?? 0, -111.65, accuracy: 1e-9)
        XCTAssertEqual(offline.westLon ?? 0, -111.95, accuracy: 1e-9)
        XCTAssertEqual(offline.latSpan ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(offline.lonSpan ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(offline.estimatedSizeMB ?? 0, 42, accuracy: 1e-9)
    }

    func testRegionBBoxRoundTrip() throws {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7, longitude: -74.0),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        let offline = OfflineRegion(label: "NYC", region: region, estimatedSizeMB: 120)
        let data = try JSONEncoder().encode(offline)
        let decoded = try JSONDecoder().decode(OfflineRegion.self, from: data)
        XCTAssertEqual(decoded, offline)
    }
}
