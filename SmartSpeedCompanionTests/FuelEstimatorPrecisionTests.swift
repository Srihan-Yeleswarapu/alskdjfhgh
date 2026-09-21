import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// FuelEstimator: consumption, cost, CO₂ for both unit systems, plus the
/// session-distance integration over SpeedReading chains (which is a
/// haversine sum — verified here against independently computed great-circle
/// distances so a formula regression cannot hide).
final class FuelEstimatorPrecisionTests: XCTestCase {

    // MARK: - Imperial math

    func testFuelUsedBasicDivision() {
        XCTAssertEqual(FuelEstimator.estimateFuelUsed(distanceMiles: 100, mpg: 25), 4.0, accuracy: 1e-9)
        XCTAssertEqual(FuelEstimator.estimateFuelUsed(distanceMiles: 33, mpg: 33), 1.0, accuracy: 1e-9)
    }

    func testFuelUsedZeroMpgReturnsZeroNotInfinity() {
        XCTAssertEqual(FuelEstimator.estimateFuelUsed(distanceMiles: 100, mpg: 0), 0)
        XCTAssertEqual(FuelEstimator.estimateFuelUsed(distanceMiles: 100, mpg: -5), 0)
    }

    func testFuelCostIsLinearProduct() {
        XCTAssertEqual(FuelEstimator.estimateFuelCost(fuelUsedGallons: 4, pricePerGallon: 3.59), 14.36, accuracy: 1e-9)
        XCTAssertEqual(FuelEstimator.estimateFuelCost(fuelUsedGallons: 0, pricePerGallon: 3.59), 0)
    }

    func testCO2ImperialConstant() {
        // 19.6 lbs CO₂ per gallon of gasoline (EPA emission factor).
        XCTAssertEqual(FuelEstimator.estimateCO2(fuelUsedGallons: 1), 19.6, accuracy: 1e-9)
        XCTAssertEqual(FuelEstimator.estimateCO2(fuelUsedGallons: 10), 196, accuracy: 1e-9)
    }

    // MARK: - Metric math

    func testFuelUsedMetricFormula() {
        // 7.5 L/100km over 400 km → 30 L.
        XCTAssertEqual(FuelEstimator.estimateFuelUsedMetric(distanceKm: 400, lPer100km: 7.5), 30, accuracy: 1e-9)
    }

    func testFuelUsedMetricZeroRateReturnsZero() {
        XCTAssertEqual(FuelEstimator.estimateFuelUsedMetric(distanceKm: 100, lPer100km: 0), 0)
    }

    func testCO2MetricConstant() {
        // 2.31 kg CO₂ per liter of gasoline.
        XCTAssertEqual(FuelEstimator.estimateCO2Metric(fuelUsedLiters: 1), 2.31, accuracy: 1e-9)
        XCTAssertEqual(FuelEstimator.estimateCO2Metric(fuelUsedLiters: 30), 69.3, accuracy: 1e-9)
    }

    // MARK: - Cross-system physical consistency

    /// The same physical trip must produce the same *physical* CO₂ in both
    /// unit systems: 10 gal × 19.6 lb/gal ≈ 196 lb ≈ 88.9 kg; metric path
    /// over the equivalent distance must land within conversion tolerance.
    func testUnitSystemsAgreePhysicallyOnCO2() {
        let miles = 250.0
        let mpg = 25.0
        let imperialCO2Lbs = FuelEstimator.estimateCO2(FuelEstimator.estimateFuelUsed(distanceMiles: miles, mpg: mpg))

        let km = miles * 1.60934
        let lPer100km = 235.215 / mpg // mpg → L/100km exact inverse
        let liters = FuelEstimator.estimateFuelUsedMetric(distanceKm: km, lPer100km: lPer100km)
        let metricCO2Kg = FuelEstimator.estimateCO2Metric(fuelUsedLiters: liters)

        let metricCO2Lbs = metricCO2Kg * 2.20462
        XCTAssertEqual(imperialCO2Lbs, metricCO2Lbs, accuracy: 1.0,
                       "Imperial and Metric CO₂ paths disagree on the same physical trip")
    }

    // MARK: - Session distance over SpeedReading chains

    private func reading(lat: Double, lon: Double, speed: Double, limit: Int, over: Bool) -> SpeedReading {
        SpeedReading(timestamp: .now, latitude: lat, longitude: lon,
                     speed: speed, speedLimit: limit, overLimit: over)
    }

    func testEmptyAndSingleReadingSessionsAreZero() {
        XCTAssertEqual(FuelEstimator.totalDistanceMiles(from: []), 0)
        let single = [reading(lat: 33.3, lon: -111.8, speed: 30, limit: 35, over: false)]
        XCTAssertEqual(FuelEstimator.totalDistanceMiles(from: single), 0)
    }

    /// One mile of eastward travel at the equator's cosine-corrected
    /// longitude — verify the sum matches the analytic distance.
    func testKnownDistanceChainSumsCorrectly() {
        // 10 fixes × 160.9344 m = 1609.344 m = exactly 1 mile.
        let lat = 33.3062
        var lon = -111.8412
        var readings: [SpeedReading] = []
        let deltaLon = 160.9344 / (111_111.0 * cos(lat * .pi / 180))
        for _ in 0..<10 {
            readings.append(reading(lat: lat, lon: lon, speed: 45, limit: 45, over: false))
            lon += deltaLon
        }
        XCTAssertEqual(FuelEstimator.totalDistanceMiles(from: readings), 1.0, accuracy: 0.01)
        XCTAssertEqual(FuelEstimator.totalDistanceKm(from: readings), 1.60934, accuracy: 0.02)
    }

    func testDistanceIsPathLengthNotDisplacement() {
        // Drive 1 km east then 1 km west: path = 2 km, displacement = 0.
        let lat = 33.3062
        let startLon = -111.8412
        let deltaLon = 1000.0 / (111_111.0 * cos(lat * .pi / 180))
        var readings: [SpeedReading] = []
        readings.append(reading(lat: lat, lon: startLon, speed: 40, limit: 45, over: false))
        readings.append(reading(lat: lat, lon: startLon + deltaLon, speed: 40, limit: 45, over: false))
        readings.append(reading(lat: lat, lon: startLon, speed: 40, limit: 45, over: false))
        XCTAssertEqual(FuelEstimator.totalDistanceMiles(from: readings), 2.0 / 1.60934, accuracy: 0.001,
                       "Distance must accumulate path length (the odometer), not displacement")
    }

    func testBackAndForthCircuitDistance() {
        // A city block circuit from GeoCorpus' turn sequence: verify total
        // against the Manhattan-style sum of the legs.
        var c = CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412)
        var readings: [SpeedReading] = []
        readings.append(reading(lat: c.latitude, lon: c.longitude, speed: 30, limit: 35, over: false))
        var expectedMeters = 0.0
        for (heading, meters) in GeoCorpus.turnSequence {
            c = GPSFixFactory.advance(c, meters: meters, heading: heading)
            readings.append(reading(lat: c.latitude, lon: c.longitude, speed: 30, limit: 35, over: false))
            expectedMeters += meters
        }
        XCTAssertEqual(FuelEstimator.totalDistanceMiles(from: readings),
                       expectedMeters / 1609.344, accuracy: 0.01)
    }

    // MARK: - Realistic trip: fuel chain integration

    /// End-to-end: a 30-mile, 28-mpg commute → gallons → cost → CO₂, the
    /// exact chain AnalyticsViewModel renders on the safety report.
    func testRealisticCommuteChain() {
        let miles = 30.0
        let mpg = 28.0
        let price = 3.79
        let gallons = FuelEstimator.estimateFuelUsed(distanceMiles: miles, mpg: mpg)
        XCTAssertEqual(gallons, 1.0714, accuracy: 0.001)
        let cost = FuelEstimator.estimateFuelCost(fuelUsedGallons: gallons, pricePerGallon: price)
        XCTAssertEqual(cost, 4.06, accuracy: 0.01)
        let co2 = FuelEstimator.estimateCO2(fuelUsedGallons: gallons)
        XCTAssertEqual(co2, 21.0, accuracy: 0.1)
    }
}
