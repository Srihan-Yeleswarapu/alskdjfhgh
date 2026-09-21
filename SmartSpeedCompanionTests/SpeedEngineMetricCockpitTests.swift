import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// The Metric cockpit end-to-end: a km/h user's limit badge, alert
/// threshold, haptic severity, buffer label, and widget label must ALL
/// agree — one conversion factor, every surface. TestFlight 2.1.4 shipped
/// a build where they didn't.
@MainActor
final class SpeedEngineMetricCockpitTests: XCTestCase {

    private var hereGate: HERECredentialsGate!
    private var defaultsGuard: UserDefaultsTestGuard!

    override func setUp() {
        super.setUp()
        hereGate = HERECredentialsGate(); hereGate.close()
        defaultsGuard = UserDefaultsTestGuard()
        defaultsGuard.snapshotNow()
        defaultsGuard.resetToFreshInstall()
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        UserDefaults.standard.set(5, forKey: "userBuffer")
    }

    override func tearDown() {
        defaultsGuard.restore()
        hereGate.reopen()
        super.tearDown()
    }

    // MARK: - Badge conversion

    func testBadgeShowsConvertedLimit() {
        // 65 mph → 105 km/h (the nearest posted-sign value).
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 65, measurementSystem: "Metric"), 105)
        XCTAssertEqual(SpeedFormatting.unitLabelShort(measurementSystem: "Metric"), "KMH")
    }

    func testBadgeConversionAcrossCommonUSLimits() {
        // The badge conversion must produce real posted-sign values.
        let conversions: [(Int, Int)] = [(25, 40), (35, 56), (45, 72), (55, 89), (65, 105), (75, 121)]
        for (mph, kmh) in conversions {
            XCTAssertEqual(SpeedFormatting.displayLimit(forMph: mph, measurementSystem: "Metric"), kmh)
        }
    }

    // MARK: - Engine threshold in km/h display space

    func testAlertThresholdInKmhDisplaySpace() {
        let engine = SpeedEngine(locationManager: LocationManager())
        // limit 65 mph, buffer 5 mph → threshold 112.65 km/h display.
        engine.speed = 100 // km/h on the dial
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .safe, "100 < 110.65 (band start)")

        engine.speed = 111
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .warning, "Inside the 2 km/h warning band")

        engine.speed = 115
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.status, .over, "115 > 112.65")
    }

    func testMetricSpeedDisplayConversion() {
        let engine = SpeedEngine(locationManager: LocationManager())
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 60))
        XCTAssertEqual(engine.speed, 60 * 1.60934, accuracy: 0.06, "96.56 km/h for a 60 mph fix")
    }

    // MARK: - Severity uses converted threshold

    func testSeverityThresholdConvertedForMetric() {
        // AlertEngine.shouldStartSpeedingPulse with Metric: threshold =
        // (limit+buffer) × 1.60934 in display units.
        let thresholdKmh = Double(65 + 5) * 1.60934 // 112.65
        XCTAssertFalse(AlertEngine.shouldStartSpeedingPulse(
            speed: thresholdKmh - 1, limit: 65, buffer: 5,
            measurementSystem: "Metric", isLimitResolved: true))
        XCTAssertTrue(AlertEngine.shouldStartSpeedingPulse(
            speed: thresholdKmh + 1, limit: 65, buffer: 5,
            measurementSystem: "Metric", isLimitResolved: true))
    }

    // MARK: - Buffer label

    func testBufferLabelConverted() {
        XCTAssertEqual(SpeedFormatting.displayBuffer(forMph: 5, measurementSystem: "Metric"), 8,
                       "Settings footer must read 'Speed Buffer: +8 km/h'")
    }

    // MARK: - Widget label agreement

    func testWidgetLabelAgreesWithBadge() {
        // The widget reads mph from the App Group and converts through the
        // same SpeedFormatting call the phone badge uses — verify both
        // surfaces produce identical strings.
        for mph in [25, 45, 65, 75] {
            let phone = SpeedFormatting.limitDisplay(forMph: mph, measurementSystem: "Metric")
            let widgetValue = SpeedFormatting.displayLimit(forMph: mph, measurementSystem: "Metric")
            let widgetUnit = SpeedFormatting.unitLabelShort(measurementSystem: "Metric")
            XCTAssertEqual(phone.value, widgetValue)
            XCTAssertEqual(phone.unit, widgetUnit)
        }
    }

    func testAppGroupUnitMirrorDrivesWidgetConversion() {
        SpeedFormatting.writeMeasurementSystemToAppGroup("Metric")
        defer {
            UserDefaults(suiteName: SpeedFormatting.appGroupSuite)?
                .removeObject(forKey: SpeedFormatting.widgetMeasurementSystemAppGroupKey)
        }
        // The widget's read path.
        let system = SpeedFormatting.measurementSystemFromAppGroup()
        XCTAssertEqual(SpeedFormatting.displayLimit(forMph: 65, measurementSystem: system), 105)
        XCTAssertEqual(SpeedFormatting.unitLabelShort(measurementSystem: system), "KMH")
    }

    // MARK: - Mixed-unit hazard: internal state stays mph

    func testInternalStateStaysMphAcrossUnitToggle() {
        let engine = SpeedEngine(locationManager: LocationManager())
        UserDefaults.standard.set("Metric", forKey: "measurementSystem")
        engine.processLocationForTesting(GPSFixFactory.fix(lat: 33.3062, lon: -111.8412, speedMph: 60))
        // engine.limit is ALWAYS mph — the badge converts at render time.
        engine.applyResolvedLimit(65)
        XCTAssertEqual(engine.limit, 65, "Stored limit must be mph, not km/h")
        // The published speed IS converted.
        XCTAssertEqual(engine.speed, 60 * 1.60934, accuracy: 0.06)
    }

    // MARK: - Distance formatting in metric

    func testNavigationDistancesAreMetric() {
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 800, measurementSystem: "Metric"), "800 m")
        XCTAssertEqual(SpeedFormatting.navigationDistanceLabel(forMeters: 1200, measurementSystem: "Metric"), "1.2 km")
    }
}
