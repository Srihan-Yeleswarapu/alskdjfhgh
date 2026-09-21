import XCTest
@testable import SmartSpeedCompanion

/// SpeedFormatting is the single conversion authority for every surface
/// (HUD, widget, Live Activity, CarPlay, safety report). TestFlight 2.1.4:
/// "When I put metric, why does speed limit show MPH still?" — every test
/// here guards one surface's dependency on this file staying correct.
final class SpeedFormattingUnitContractTests: XCTestCase {

    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
    }

    override func tearDown() {
        defaultsGuard.restore()
        super.tearDown()
    }

    // MARK: - Constants

    func testConversionConstantsAreSiCanonical() {
        XCTAssertEqual(SpeedFormatting.kmhPerMph, 1.60934, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatting.metersPerMile, 1609.344, accuracy: 1e-9)
        XCTAssertEqual(SpeedFormatting.feetPerMeter, 3.28084, accuracy: 1e-4)
        XCTAssertEqual(SpeedFormatting.metersPerKilometer, 1000, accuracy: 1e-9)
    }

    func testAppGroupSuiteNameMatchesEntitlementsCapability() {
        XCTAssertEqual(SpeedFormatting.appGroupSuite, "group.com.smartspeedcompanion.app")
    }

    // MARK: - Limit conversion

    func testDisplayLimitImperialIsIdentity() {
        for mph in [15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80] {
            XCTAssertEqual(SpeedFormatting.displayLimit(forMph: mph, measurementSystem: "Imperial"), mph)
        }
    }

    func testDisplayLimitMetricRoundsToNearestFive() {
        // Posted signs are multiples of 5 km/h — the conversion must land
        // on them for the common US limits, or the badge shows impossible
        // values like 104 km/h.
        let pairs: [(Int, Int)] = [
            (15, 24), (20, 32), (25, 40), (30, 48), (35, 56),
            (40, 64), (45, 72), (50, 80), (55, 89), (60, 97),
            (65, 105), (70, 113), (75, 121), (80, 129),
        ]
        for (mph, expectedKmh) in pairs {
            XCTAssertEqual(SpeedFormatting.displayLimit(forMph: mph, measurementSystem: "Metric"),
                           expectedKmh, "\(mph) mph must display as \(expectedKmh) km/h")
        }
    }

    func testDisplayLimitRoundTripLosesAtMostOneMph() {
        for mph in stride(from: 10, through: 90, by: 5) {
            let kmh = SpeedFormatting.displayLimit(forMph: mph, measurementSystem: "Metric")
            let back = Double(kmh) / SpeedFormatting.kmhPerMph
            XCTAssertEqual(back, Double(mph), accuracy: 1.0,
                           "Round-trip \(mph) mph drifted more than 1 mph")
        }
    }

    // MARK: - Buffer conversion

    func testDisplayBufferImperialAndMetric() {
        XCTAssertEqual(SpeedFormatting.displayBuffer(forMph: 5, measurementSystem: "Imperial"), 5)
        XCTAssertEqual(SpeedFormatting.displayBuffer(forMph: 5, measurementSystem: "Metric"), 8,
                       "+5 mph buffer shows as +8 km/h")
        XCTAssertEqual(SpeedFormatting.displayBuffer(forMph: -5, measurementSystem: "Metric"), -8,
                       "Negative buffers convert with sign")
    }

    // MARK: - Unit labels

    func testUnitLabelsEverySurface() {
        XCTAssertEqual(SpeedFormatting.unitLabelShort(measurementSystem: "Imperial"), "MPH")
        XCTAssertEqual(SpeedFormatting.unitLabelShort(measurementSystem: "Metric"), "KMH")
        XCTAssertEqual(SpeedFormatting.unitLabelLong(measurementSystem: "Imperial"), "mph")
        XCTAssertEqual(SpeedFormatting.unitLabelLong(measurementSystem: "Metric"), "km/h")
    }

    func testUnknownMeasurementSystemFallsBackToImperial() {
        XCTAssertEqual(SpeedFormatting.unitLabelShort(measurementSystem: "nonsense"), "MPH")
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 65, measurementSystem: ""), 65)
    }

    func testLimitDisplayTupleIsConsistent() {
        let imperial = SpeedFormatting.limitDisplay(forMph: 65, measurementSystem: "Imperial")
        XCTAssertEqual(imperial.value, 65)
        XCTAssertEqual(imperial.unit, "MPH")

        let metric = SpeedFormatting.limitDisplay(forMph: 65, measurementSystem: "Metric")
        XCTAssertEqual(metric.value, 105)
        XCTAssertEqual(metric.unit, "KMH")
    }

    // MARK: - Distance display (voice + safety report)

    func testDistanceDisplayImperialMilesAndFeet() {
        let miles = SpeedFormatting.distanceDisplay(forMeters: 1609.344 * 3, measurementSystem: "Imperial")
        XCTAssertEqual(miles.value, 3, accuracy: 0.001)
        XCTAssertEqual(miles.unit, "miles")

        let feet = SpeedFormatting.distanceDisplay(forMeters: 100, measurementSystem: "Imperial")
        XCTAssertEqual(feet.value, 328.084, accuracy: 0.01)
        XCTAssertEqual(feet.unit, "feet")
    }

    func testDistanceDisplayMetricKilometersAndMeters() {
        let km = SpeedFormatting.distanceDisplay(forMeters: 1500, measurementSystem: "Metric")
        XCTAssertEqual(km.value, 1.5, accuracy: 0.001)
        XCTAssertEqual(km.unit, "kilometers")

        let m = SpeedFormatting.distanceDisplay(forMeters: 200, measurementSystem: "Metric")
        XCTAssertEqual(m.value, 0.2, accuracy: 0.001)
        XCTAssertEqual(m.unit, "kilometers",
                       "distanceDisplay returns coarse units; navigationDistanceLabel does the m/ft split")
    }

    // MARK: - Navigation distance labels (the CarPlay/phone parity policy)

    func testNavigationLabelFeetBelowOneThousand() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 60, measurementSystem: "Imperial"), "200 ft")
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 300, measurementSystem: "Imperial"), "1000 ft",
                       "Boundary: exactly 1000 ft still formats as feet")
    }

    func testNavigationLabelMilesAbove() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 2000, measurementSystem: "Imperial"), "1.2 mi")
    }

    func testNavigationLabelMetricMetersBelowKilometer() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 300, measurementSystem: "Metric"), "300 m")
        // Rounding policy: multiples of 50, floor 50.
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 22, measurementSystem: "Metric"), "50 m",
                       "Tiny distances clamp to the 50 m floor instead of showing 0 m")
    }

    func testNavigationLabelMetricKilometersAbove() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 2500, measurementSystem: "Metric"), "2.5 km")
    }

    func testNavigationLabelNeverNegative() {
        let label = SpeedFormatting.navigationDistanceLabel(forMeters: -100, measurementSystem: "Imperial")
        XCTAssertEqual(label, "0.0 mi", "Overshoot past a maneuver must clamp to zero distance")
    }

    func testNavigationMeasurementMatchesLabelForImperial() {
        for meters in [50.0, 250.0, 700.0, 1500.0, 20_000.0] {
            let measurement = SpeedFormatting.navigationDistanceMeasurement(forMeters: meters, measurementSystem: "Imperial")
            let label = SpeedFormatting.navigationDistanceLabel(forMeters: meters, measurementSystem: "Imperial")
            XCTAssertTrue(label.hasSuffix(measurement.unit.symbol) || label.contains(measurement.unit.symbol),
                          "Label '\(label)' and measurement unit '\(measurement.unit.symbol)' disagree at \(meters) m")
        }
    }

    func testNavigationUnitSymbolPolicy() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(forMeters: 100, measurementSystem: "Imperial"), "ft")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(forMeters: 5000, measurementSystem: "Imperial"), "mi")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(forMeters: 100, measurementSystem: "Metric"), "m")
        XCTAssertEqual(SpeedFormatting.navigationDistanceUnit(forMeters: 5000, measurementSystem: "Metric"), "km")
    }

    // MARK: - App Group mirror (widget/Live-Activity dependency)

    func testMeasurementSystemReadsStandardDefaults() {
        UserDefaults.standard.set("Metric", forKey: SpeedFormatting.measurementSystemDefaultsKey)
        XCTAssertEqual(SpeedFormatting.measurementSystem(), "Metric")
        UserDefaults.standard.set("Imperial", forKey: SpeedFormatting.measurementSystemDefaultsKey)
        XCTAssertEqual(SpeedFormatting.measurementSystem(), "Imperial")
        UserDefaults.standard.removeObject(forKey: SpeedFormatting.measurementSystemDefaultsKey)
        XCTAssertEqual(SpeedFormatting.measurementSystem(), "Imperial", "Unset defaults to Imperial")
    }

    func testAppGroupMirrorWritesAndReads() {
        SpeedFormatting.writeMeasurementSystemToAppGroup("Metric")
        XCTAssertEqual(SpeedFormatting.measurementSystemFromAppGroup(), "Metric")
        SpeedFormatting.writeMeasurementSystemToAppGroup("Imperial")
        XCTAssertEqual(SpeedFormatting.measurementSystemFromAppGroup(), "Imperial")
        // Restore so the operator's real widget preference is untouched.
        UserDefaults(suiteName: SpeedFormatting.appGroupSuite)?
            .removeObject(forKey: SpeedFormatting.widgetMeasurementSystemAppGroupKey)
    }

    func testIsMetricPredicate() {
        XCTAssertTrue(SpeedFormatting.isMetric("Metric"))
        XCTAssertFalse(SpeedFormatting.isMetric("Imperial"))
        XCTAssertFalse(SpeedFormatting.isMetric("metric"), "Case-sensitive by contract — Settings writes the exact literal")
    }
}
