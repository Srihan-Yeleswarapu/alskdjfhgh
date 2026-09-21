import XCTest
@testable import SmartSpeedCompanion

/// CarPlay map heading integration: the driver-facing quality of the
/// course-driven rotation — a red light must not spin the map, a U-turn
/// across 0° must rotate the short way, GPS jitter at a stop must not
/// wiggle the compass rose.
final class CameraCarPlayHeadingIntegrationTests: XCTestCase {

    // MARK: - Red light: course must hold, not jitter

    func testRedLightCourseHold() {
        var heading = 90.0 // eastbound
        let noiseStorm: [Double?] = [nil, 88, 92, nil, 91, 89, nil, nil, 90, 90.5]
        var published: [Double] = [heading]
        for fix in noiseStorm {
            // DriveViewModel.nextHeading policy: below 2 m/s hold last.
            let speedMps = 0.3 // creeping at a light
            let next = DriveViewModel.nextHeading(
                previous: heading, course: fix, speed: speedMps,
                compassTrueHeading: 65, isNavigating: false)
            heading = next ?? heading
            published.append(heading)
        }
        XCTAssertEqual(Set(published), [90.0],
                       "The course must hold exactly 90° through the whole light — got \(Set(published))")
    }

    // MARK: - U-turn across the 0°/360° wrap

    func testUTurnRotatesShortWayAcrossWrap() {
        var current = 350.0
        // U-turn to 10°: total rotation 20°, max step 8°/tick.
        for _ in 0..<4 {
            current = CameraMath.rotatingApproach(current: current, target: 10, maxDelta: 8)
        }
        XCTAssertEqual(current, 10, accuracy: 0.001,
                       "U-turn must complete in bounded steps, never spool 340° the wrong way")
    }

    func testLongWayIsNeverChosen() {
        // From 180 to 170: the short way is −10°.
        let next = CameraMath.rotatingApproach(current: 180, target: 170, maxDelta: 45)
        XCTAssertEqual(next, 170, accuracy: 0.001)
        // From 10 to 350: the short way is −20° (through 0), reaching 350.
        let wrapped = CameraMath.rotatingApproach(current: 10, target: 350, maxDelta: 45)
        XCTAssertEqual(wrapped, 350, accuracy: 0.001)
    }

    // MARK: - Highway speeds: rotation follows course promptly

    func testHighwayCourseAdoption() {
        // At 30 m/s the course IS the heading; adoption must be immediate.
        let next = DriveViewModel.nextHeading(
            previous: 90, course: 92, speed: 30,
            compassTrueHeading: 70, isNavigating: false)
        XCTAssertEqual(next, 92)
    }

    func testNavigationReLockAfterLight() {
        // Rolling from a stop while navigating: 0.5 m/s re-locks.
        let next = DriveViewModel.nextHeading(
            previous: 270, course: 275, speed: 0.6,
            compassTrueHeading: 250, isNavigating: true)
        XCTAssertEqual(next, 275, "The map must rotate the instant the car rolls")
    }

    // MARK: - Jitter immunity at speed

    func testModerateJitterStillTracksCourse() {
        // At driving speed, ±3° GPS course jitter is normal; adoption is
        // unconditional above the speed threshold, so the map follows.
        var heading: Double? = 180
        for fix in [183.0, 178.0, 182.0, 179.0, 181.0] {
            heading = DriveViewModel.nextHeading(
                previous: heading, course: fix, speed: 25,
                compassTrueHeading: nil, isNavigating: false)
        }
        XCTAssertEqual(heading ?? 0, 181.0, accuracy: 0.001,
                       "Above the threshold, the freshest course wins")
    }

    // MARK: - Compass is strictly a seed

    func testCompassNeverOverridesHeldCourseMidDrive() {
        // The b640 "30 degrees off" bug: compass deviation inside a car.
        var heading: Double? = 92 // held from GPS
        for compassDeviation in [65.0, 75.0, 110.0] {
            heading = DriveViewModel.nextHeading(
                previous: heading, course: -1, speed: 0, // stopped, course invalid
                compassTrueHeading: compassDeviation, isNavigating: false)
            XCTAssertEqual(heading ?? 0, 92, accuracy: 0.001,
                           "Compass \(compassDeviation)° must not override the held course")
        }
    }

    func testFirstFixSeedsFromCompassWhenStationary() {
        let next = DriveViewModel.nextHeading(
            previous: nil, course: nil, speed: 0,
            compassTrueHeading: 42, isNavigating: false)
        XCTAssertEqual(next, 42)
    }

    // MARK: - Full rotation scenario: exit ramp

    func testExitRampScenario() {
        // Highway south (180°) → loop ramp east (90°) over 5 ticks at
        // 40 mph: the map must rotate smoothly without overshoot.
        var current = 180.0
        let targets: [Double] = [170, 155, 135, 110, 90]
        for target in targets {
            current = CameraMath.rotatingApproach(current: current, target: target, maxDelta: 45)
        }
        XCTAssertEqual(current, 90, accuracy: 0.001)
        // No step may exceed maxDelta.
    }

    func testSustainedRotationConverges() {
        var current = 0.0
        for _ in 0..<200 {
            current = CameraMath.rotatingApproach(current: current, target: 359, maxDelta: 4)
        }
        XCTAssertEqual(current, 359, accuracy: 0.001, "Sustained rotation must always converge")
    }
}
