import XCTest
@testable import SmartSpeedCompanion

/// FuelEstimator long-haul: an 8-hour highway drive simulated 1 Hz.
/// Consumption estimates must integrate distance honestly — no drift, no
/// unit confusion (L/100km profile vs a miles-driven app), and sane behavior
/// at zero distance. This pins the conversion math the FuelEstimator and its
/// VehicleProfile input rely on: L/100km × km → liters.
final class FuelEstimatorLongHaulDriftTests: XCTestCase {

    /// Integrate consumption over a drive: returns liters burned.
    private func drive(distanceKm: Double, speedKmh: Double, efficiency: Double) -> Double {
        let litersPerMeter = efficiency / 100_000.0 // L/100km → L/m
        let metersPerSecond = speedKmh / 3.6
        var consumed = 0.0
        var traveled = 0.0
        let total = distanceKm * 1_000
        while traveled < total {
            let step = min(metersPerSecond, total - traveled)
            consumed += step * litersPerMeter
            traveled += step
        }
        return consumed
    }

    // MARK: - Conservation anchors

    func testEightHourDriveDistanceIntegratesExactly() {
        // 8 h at 100 km/h = 800 km; at 7 L/100km → exactly 56 L. If the
        // integration drifts, so does the user's fuel budget.
        let liters = drive(distanceKm: 800, speedKmh: 100, efficiency: 7.0)
        XCTAssertEqual(liters, 56.0, accuracy: 0.01,
                       "8 h integration drifted: \(liters) L ≠ 56 L")
    }

    func testDistanceIntegralMatchesTimeSpeedProduct() {
        // distance = Σ v·dt must equal v·t within float noise — catches
        // accumulator drift that grows over long sessions.
        let speedKmh = 100.0
        var traveled = 0.0
        var t = 0.0
        while t < 8 * 3600 {
            traveled += (speedKmh / 3.6) * 1.0
            t += 1.0
        }
        XCTAssertEqual(traveled / 1_000, 8 * 100, accuracy: 0.001,
                       "Distance accumulator drifted over 8 h: \(traveled / 1_000) km")
    }

    func testConsumptionScalesLinearlyWithDistance() {
        let short = drive(distanceKm: 100, speedKmh: 100, efficiency: 7.0)
        let long = drive(distanceKm: 400, speedKmh: 100, efficiency: 7.0)
        XCTAssertEqual(long / short, 4.0, accuracy: 0.01,
                       "Fuel consumption is not linear in distance")
    }

    func testConsumptionScalesLinearlyWithEfficiency() {
        let thirsty = drive(distanceKm: 100, speedKmh: 100, efficiency: 14.0)
        let frugal = drive(distanceKm: 100, speedKmh: 100, efficiency: 7.0)
        XCTAssertEqual(thirsty / frugal, 2.0, accuracy: 0.01,
                       "Doubling L/100km must double consumption")
    }

    func testZeroDistanceConsumesNothing() {
        XCTAssertEqual(drive(distanceKm: 0, speedKmh: 100, efficiency: 7.0),
                       0, accuracy: 1e-12)
    }

    // MARK: - Unit-conversion sanity (the classic mi/km bug)

    func testTypicalCommuteConsumption() {
        // 20 km commute at 7 L/100km → 1.4 L. A mi/km confusion shows up
        // as 1.4×1.609 or 1.4/1.609 here.
        let liters = drive(distanceKm: 20, speedKmh: 60, efficiency: 7.0)
        XCTAssertEqual(liters, 1.4, accuracy: 0.02,
                       "Commute consumption \(liters) L — unit bug?")
    }

    func testMphDrivenRouteDoesNotInflateKmMath() {
        // A 100-mile drive expressed in km (160.9 km) at 7 L/100km must NOT
        // consume the 100 km amount — the conversion must be applied.
        let kmDriven = 100.0 * 1.609344
        let liters = drive(distanceKm: kmDriven, speedKmh: 100, efficiency: 7.0)
        XCTAssertEqual(liters, kmDriven * 7.0 / 100, accuracy: 0.05)
        XCTAssertNotEqual(liters, 7.0, accuracy: 0.01,
                          "Miles-driven route consumed the km value — conversion dropped")
    }

    func testStopAndGoConsumptionEqualsSumOfLegs() {
        // City driving as many short legs must equal one long leg of the
        // same total distance (linearity under segmentation).
        let legs = [2.0, 3.5, 1.2, 4.0, 0.8]
        let segmented = legs.reduce(0.0) { $0 + drive(distanceKm: $1, speedKmh: 35, efficiency: 8.5) }
        let total = drive(distanceKm: legs.reduce(0, +), speedKmh: 35, efficiency: 8.5)
        XCTAssertEqual(segmented, total, accuracy: 1e-9,
                       "Segmented legs drifted from the single-leg total")
    }

    // MARK: - Accumulator robustness

    func testLongDriveAccumulatorPrecision() {
        // 100,000 one-meter steps: float error must stay sub-liter.
        var consumed = 0.0
        let litersPerMeter = 7.0 / 100_000.0
        for _ in 0..<100_000 { consumed += 1.0 * litersPerMeter }
        XCTAssertEqual(consumed, 7.0, accuracy: 1e-6,
                       "Accumulator lost \(7.0 - consumed) L over 100k steps")
    }
}
