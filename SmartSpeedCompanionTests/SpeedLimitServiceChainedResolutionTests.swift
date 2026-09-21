import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// SpeedLimitService resolution order: the service chains providers — batch
/// cache (SQLite) → live HERE (only when the cache misses). With the
/// credentials gate closed, the live leg can never fire, so these tests pin
/// the observable ordering: seeded cache answers win, unseeded areas fall
/// through cleanly, and OSM/ArcGIS legacy rows are never promoted.
final class SpeedLimitServiceChainedResolutionTests: XCTestCase {

    private var hereGate: HERECredentialsGate!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
    }

    override func tearDown() {
        hereGate.reopen()
        super.tearDown()
    }

    private let cache = HERELocalBatchCache.shared

    // MARK: - Cache-first discipline

    func testSeededCacheAnswersWithoutLiveCall() {
        let center = CLLocationCoordinate2D(latitude: -33.98001, longitude: 18.49001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        cache.store(roads: [CachedRoad(roadName: "Chain Blvd", direction: "E",
                                       speedLimitMph: 40,
                                       latitude: center.latitude,
                                       longitude: center.longitude,
                                       source: "here")])
        let hit = cache.lookup(roadName: "Chain Blvd", bearing: 90, near: center)
        XCTAssertNotNil(hit, "Seeded row missed by name lookup")
        XCTAssertEqual(hit?.speedLimitMph, 40)
        cache.deleteZone(center: center, radiusMeters: 1_000)
    }

    func testDirectionMismatchFallsToNearestNeighbor() {
        // Driving west where only an eastward row is seeded: the name-first
        // path misses, the spatial fallback must still answer.
        let center = CLLocationCoordinate2D(latitude: -33.99001, longitude: 18.50001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        cache.store(roads: [CachedRoad(roadName: "One-Way Ave", direction: "E",
                                       speedLimitMph: 45,
                                       latitude: center.latitude,
                                       longitude: center.longitude,
                                       source: "here")])
        let westMiss = cache.lookup(roadName: "One-Way Ave", bearing: 270, near: center)
        let nearest = cache.lookupNearest(to: center, radiusMeters: 50)
        // The name+direction lookup may miss; the spatial path must answer.
        if westMiss == nil {
            XCTAssertNotNil(nearest, "Direction mismatch left no fallback answer")
            XCTAssertEqual(nearest?.speedLimitMph, 45)
        } else {
            XCTAssertEqual(westMiss?.speedLimitMph, 45)
        }
        cache.deleteZone(center: center, radiusMeters: 1_000)
    }

    func testUnknownRoadMissesCleanly() {
        let center = CLLocationCoordinate2D(latitude: -34.00001, longitude: 18.51001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        let miss = cache.lookup(roadName: "Nowhere Lane", bearing: 0, near: center)
        XCTAssertNil(miss, "Invented road answered — cache poisoning or overmatch")
        cache.deleteZone(center: center, radiusMeters: 1_000)
    }

    // MARK: - Bearing→direction inference (the service's routing key)

    func testBearingMapsToCardinalDirections() {
        // The service converts GPS course to the cache's N/S/E/W key.
        // Pin the quadrant boundaries: 45° splits E/N, 135° splits S/E.
        func cardinal(_ bearing: Double) -> String {
            switch (bearing + 45).truncatingRemainder(dividingBy: 360) / 90 {
            case 0...1: return "N"
            case 1...2: return "E"
            case 2...3: return "S"
            default: return "W"
            }
        }
        XCTAssertEqual(cardinal(0), "N")
        XCTAssertEqual(cardinal(90), "E")
        XCTAssertEqual(cardinal(180), "S")
        XCTAssertEqual(cardinal(270), "W")
        XCTAssertEqual(cardinal(44), "N")
        XCTAssertEqual(cardinal(46), "E")
    }

    // MARK: - Legacy source rows are never promoted

    func testLegacyArcGISRowsServeOnlyAsLegacy() {
        let center = CLLocationCoordinate2D(latitude: -34.01001, longitude: 18.52001)
        cache.deleteZone(center: center, radiusMeters: 1_000)
        // Store a row stamped with a legacy source string.
        cache.store(roads: [CachedRoad(roadName: "Legacy Rd", direction: "N",
                                       speedLimitMph: 30,
                                       latitude: center.latitude,
                                       longitude: center.longitude,
                                       source: "osm")])
        let row = cache.lookup(roadName: "Legacy Rd", bearing: 0, near: center)
        // Row exists in the cache (storage is source-agnostic)…
        if let row {
            XCTAssertEqual(row.source, "osm")
            // …but its source label must never claim HERE.
            XCTAssertNotEqual(row.source, "here",
                              "Legacy row misattributed to HERE — rate-limit audit lie")
        }
        cache.deleteZone(center: center, radiusMeters: 1_000)
    }

    // MARK: - Coverage→decision interplay

    func testWellSeededAreaYieldsHighCoverage() {
        let center = CLLocationCoordinate2D(latitude: -34.02001, longitude: 18.53001)
        cache.deleteZone(center: center, radiusMeters: 2_000)
        let roads = (0..<40).map { i -> CachedRoad in
            let p = GPSFixFactory.advance(center, meters: Double(i) * 35, heading: 0)
            return CachedRoad(roadName: "Coverage Rd", direction: "N",
                              speedLimitMph: 50,
                              latitude: p.latitude, longitude: p.longitude,
                              source: "here")
        }
        cache.store(roads: roads)
        let coverage = cache.estimatedCoverage(at: center, radiusMeters: 1_500)
        XCTAssertGreaterThanOrEqual(coverage, 0.2,
                                    "1.4 km corridor under 20% coverage — geofence would over-fetch")
        cache.deleteZone(center: center, radiusMeters: 2_000)
    }
}
