import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The offline-download sheet renders `OfflineLimitsEstimate.sizeLabel` and
/// `.timeLabel` directly to the user. This file stress-tests the label
/// formatting at every boundary the formatter branches on (1023→1024,
/// kB→MB thresholds, sub-second, minute wraps) and pins the compatibility
/// downloader's contract: heuristic, offline-safe, no network.
///
/// No HERE requests — this whole subsystem is deliberately network-free.
final class OfflineLimitsEstimateLabelStressTests: XCTestCase {

    // MARK: - sizeLabel boundaries

    func testSizeLabelBelowKilobyteUsesBytes() {
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 0, estimatedSeconds: 1, isReal: false).sizeLabel, "0 B")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 1, isReal: false).sizeLabel, "1 B")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 999, estimatedSeconds: 1, isReal: false).sizeLabel, "999 B")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1023, estimatedSeconds: 1, isReal: false).sizeLabel, "1023 B")
    }

    func testSizeLabelKilobyteBoundaryIsInclusive() {
        // Exactly 1024 flips to kB (the formatter checks < 1024).
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1024, estimatedSeconds: 1, isReal: false).sizeLabel, "1 kB")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1025, estimatedSeconds: 1, isReal: false).sizeLabel, "1 kB")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 2048, estimatedSeconds: 1, isReal: false).sizeLabel, "2 kB")
        // kB branch renders with no decimals.
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1536, estimatedSeconds: 1, isReal: false).sizeLabel, "2 kB")
    }

    func testSizeLabelMegabyteBoundaryIsInclusive() {
        let mb = 1024 * 1024
        // 1023.5 kB rounds inside the kB branch...
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: mb - 512, estimatedSeconds: 1, isReal: false).sizeLabel, "1024 kB")
        // ...exactly 1 MB flips to the MB branch with one decimal.
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: mb, estimatedSeconds: 1, isReal: false).sizeLabel, "1.0 MB")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: mb + 1, estimatedSeconds: 1, isReal: false).sizeLabel, "1.0 MB")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: Int64(2.5 * Double(mb)), estimatedSeconds: 1, isReal: false).sizeLabel, "2.5 MB")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: Int64(25.0 * Double(mb)), estimatedSeconds: 1, isReal: false).sizeLabel, "25.0 MB")
    }

    func testSizeLabelNeverProducesGarbageForTypicalRegions() {
        // Realistic road-count × per-road payload sweep: every label must parse
        // as "<number> <unit>" with a sane unit.
        let units: Set<String> = ["B", "kB", "MB"]
        for roads in stride(from: 100, through: 50_000, by: 997) {
            for bytesPerRoad in [400, 900, 2_000, 5_000] {
                let est = OfflineLimitsEstimate(
                    roadCount: roads, sizeBytes: Int64(roads * bytesPerRoad),
                    estimatedSeconds: 60, isReal: false)
                let parts = est.sizeLabel.split(separator: " ")
                XCTAssertEqual(parts.count, 2, "sizeLabel '\(est.sizeLabel)' not two tokens")
                XCTAssertNotNil(Double(parts[0]), "non-numeric size in '\(est.sizeLabel)'")
                XCTAssertTrue(units.contains(String(parts[1])), "unknown unit in '\(est.sizeLabel)'")
            }
        }
    }

    // MARK: - timeLabel boundaries

    func testTimeLabelSubMinuteAlwaysShowsAtLeastOneSecond() {
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 0, isReal: false).timeLabel, "~1 s")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 1, isReal: false).timeLabel, "~1 s")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 30, isReal: false).timeLabel, "~30 s")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 59, isReal: false).timeLabel, "~59 s")
        // Negative input is clamped by max(1, ...) rather than rendering "~0 s".
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: -5, isReal: false).timeLabel, "~1 s")
    }

    func testTimeLabelMinuteWraps() {
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 60, isReal: false).timeLabel, "~1 min")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 90, isReal: false).timeLabel, "~1 min 30 s")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 119, isReal: false).timeLabel, "~1 min 59 s")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 120, isReal: false).timeLabel, "~2 min")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 3_725, isReal: false).timeLabel, "~62 min 5 s")
    }

    func testTimeLabelWholeMinutesOmitSeconds() {
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 300, isReal: false).timeLabel, "~5 min")
        XCTAssertEqual(OfflineLimitsEstimate(roadCount: 1, sizeBytes: 1, estimatedSeconds: 3_600, isReal: false).timeLabel, "~60 min")
    }

    // MARK: - Compatibility downloader contract

    func testCompatibilityEstimateNeverClaimsToBeReal() async {
        // The type exists purely so legacy call sites compile; it must never
        // masquerade as a live Overpass/HERE-backed estimate.
        let result = await OfflineLimitsDownloader.shared.estimate(
            center: CLLocationCoordinate2D(latitude: 33.4484, longitude: -112.0740),
            radiusMiles: 5)
        XCTAssertFalse(result.isReal, "Compatibility estimate must be flagged heuristic")
        XCTAssertGreaterThan(result.roadCount, 0, "UI needs a positive road count to render")
        XCTAssertGreaterThan(result.sizeBytes, 0)
    }

    func testCompatibilityEstimateScalesMonotonicallyWithRadius() async {
        var previous = 0
        for radius in [1.0, 2.0, 5.0, 10.0, 25.0] {
            let est = await OfflineLimitsDownloader.shared.estimate(
                center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
                radiusMiles: radius)
            XCTAssertGreaterThan(est.roadCount, previous,
                                 "roadCount must grow with radius (broke at \(radius) mi)")
            previous = est.roadCount
        }
    }

    func testCompatibilityEstimateIsRadiusProportionalAcrossCities() async {
        // The heuristic should be geography-independent (it ignores `center`).
        let cities = [
            CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278),   // London
            CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503), // Tokyo
            CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093) // Sydney
        ]
        var counts: [Int] = []
        for city in cities {
            let est = await OfflineLimitsDownloader.shared.estimate(center: city, radiusMiles: 3)
            counts.append(est.roadCount)
        }
        XCTAssertEqual(Set(counts).count, 1, "heuristic must not vary by center")
    }

    func testCompatibilityResultLabelsRoundTripThroughEstimate() async {
        let est = await OfflineLimitsDownloader.shared.estimate(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0), radiusMiles: 2)
        XCTAssertFalse(est.sizeLabel.isEmpty)
        XCTAssertFalse(est.timeLabel.isEmpty)
        XCTAssertFalse(est.sizeLabel.contains("nan"), "no NaN leakage into labels")
        XCTAssertFalse(est.timeLabel.contains("nan"))
    }
}
