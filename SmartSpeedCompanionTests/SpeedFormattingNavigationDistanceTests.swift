import XCTest
@testable import SmartSpeedCompanion

/// SpeedFormatting's navigation distance policy: the SAME threshold rules
/// must produce identical strings on phone, CarPlay, and the Live Activity.
/// An 800-ft maneuver showing "0.2 mi" on CarPlay while the phone says
/// "800 ft" is the exact regression this file pins. Pure formatting, no
/// network of any kind.
final class SpeedFormattingNavigationDistanceTests: XCTestCase {

    // MARK: - Imperial thresholds

    func testImperialShortDistanceUsesFeet() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 100, measurementSystem: "Imperial"), "300 ft")
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 60.96, measurementSystem: "Imperial"), "200 ft") // 200 ft exact
    }

    func testImperialLongDistanceUsesMiles() {
        // 1,609 m ≈ 5,280 ft ≥ 1,000 ft → miles.
        let label = SpeedFormatting.navigationDistanceLabel(
            forMeters: 1_700, measurementSystem: "Imperial")
        XCTAssertTrue(label.hasSuffix("mi"), "Long imperial distance got \(label)")
        XCTAssertFalse(label.contains("ft"))
    }

    func testImperialThresholdAt999FeetStaysFeet() {
        let label = SpeedFormatting.navigationDistanceLabel(
            forMeters: 304, measurementSystem: "Imperial") // ~997 ft
        XCTAssertTrue(label.hasSuffix("ft"), "999 ft boundary flipped early: \(label)")
    }

    func testImperialRoundsFeetToHundreds() {
        // 402.3 m = 1,320 ft → rounds to 1,300 ft… but that's ≥1,000 ft, so
        // it becomes miles. Use sub-1000 ft: 243.8 m = 800 ft.
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 243.84, measurementSystem: "Imperial"), "800 ft")
        // 250.0 m = 820.2 ft → rounds to 800 ft.
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 250.0, measurementSystem: "Imperial"), "800 ft")
    }

    // MARK: - Metric thresholds

    func testMetricShortDistanceUsesMeters() {
        let label = SpeedFormatting.navigationDistanceLabel(
            forMeters: 300, measurementSystem: "Metric")
        XCTAssertTrue(label.hasSuffix("m"), "Short metric distance got \(label)")
        XCTAssertEqual(label, "300 m")
    }

    func testMetricLongDistanceUsesKm() {
        let label = SpeedFormatting.navigationDistanceLabel(
            forMeters: 1_500, measurementSystem: "Metric")
        XCTAssertTrue(label.hasSuffix("km"), "Long metric distance got \(label)")
        XCTAssertEqual(label, "1.5 km")
    }

    func testMetricRoundsMetersToFifties() {
        // 312 m → rounds to 300 m (50 m step).
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 312, measurementSystem: "Metric"), "300 m")
    }

    func testMetricFloorAt50Meters() {
        // 10 m must display as 50 m — never "0 m", never "10 m" (too
        // precise for a driver at speed).
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 10, measurementSystem: "Metric"), "50 m")
    }

    func testImperialFloorAt100Feet() {
        // 5 m = 16 ft must clamp to 100 ft.
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 5, measurementSystem: "Imperial"), "100 ft")
    }

    // MARK: - Negative / degenerate input

    func testNegativeDistanceClampsToFloor() {
        // GPS jitter produces small negatives near the maneuver point.
        let label = SpeedFormatting.navigationDistanceLabel(
            forMeters: -30, measurementSystem: "Imperial")
        XCTAssertFalse(label.hasPrefix("-"), "Negative distance leaked: \(label)")
        XCTAssertEqual(label, "100 ft")
    }

    func testZeroDistanceClampsToFloor() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 0, measurementSystem: "Imperial"), "100 ft")
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(
            forMeters: 0, measurementSystem: "Metric"), "50 m")
    }

    // MARK: - Unit symbols & measurement tuples

    func testNavigationUnitSymbolMatchesLabelSystem() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(
            forMeters: 800, measurementSystem: "Imperial"), "ft")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(
            forMeters: 8_000, measurementSystem: "Imperial"), "mi")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(
            forMeters: 800, measurementSystem: "Metric"), "m")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(
            forMeters: 8_000, measurementSystem: "Metric"), "km")
    }

    func testDistanceDisplayTupleWordUnits() {
        // Voice-facing tuples use words ("feet", "miles") not symbols.
        let imperialNear = SpeedFormatting.distanceDisplay(
            forMeters: 200, measurementSystem: "Imperial")
        XCTAssertEqual(imperialNear.unit, "feet")
        let imperialFar = SpeedFormatting.distanceDisplay(
            forMeters: 20_000, measurementSystem: "Imperial")
        XCTAssertEqual(imperialFar.unit, "miles")
        let metric = SpeedFormatting.distanceDisplay(
            forMeters: 500, measurementSystem: "Metric")
        XCTAssertEqual(metric.unit, "kilometers")
        XCTAssertEqual(metric.value, 0.5, accuracy: 1e-9)
    }

    // MARK: - Canonical constants (audited single source of truth)

    func testConversionConstantsAreCanonical() {
        XCTAssertEqual(SpeedFormatting.kmhPerMph, 1.60934, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatting.metersPerMile, 1609.344, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatting.feetPerMeter, 3.28084, accuracy: 1e-4)
        XCTAssertEqual(SpeedFormatting.metersPerKilometer, 1_000)
    }

    // MARK: - Limit display round-trip

    func testLimitDisplayMetricRoundsToPostedSign() {
        // 65 mph → 105 km/h (nearest 5-multiple posting), never 104.6.
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 65, measurementSystem: "Metric"), 105)
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 30, measurementSystem: "Metric"), 48)
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 65, measurementSystem: "Imperial"), 65)
    }
}
