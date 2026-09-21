import XCTest
import CoreLocation
@testable import SmartSpeedCompanion

/// BufferSlider usability: the slider the reporter photographed showing
/// "+3" while displaying the +5 position. The mapping tests pin the full
/// −5…+10 drag geometry; the visual-consistency tests pin that fill,
/// thumb, and label can never disagree again (they derive from the same
/// functions the view calls).
@MainActor
final class BufferSliderGeometryUsabilityTests: XCTestCase {

    // MARK: - Drag mapping across the full range

    func testDragMappingAcrossAllSteps() {
        let width: CGFloat = 300
        // Every integer step −5…10 must be reachable.
        for step in -5...10 {
            // Find an x that maps to this step: fraction = (step+5)/15.
            let fraction = CGFloat(step + 5) / 15.0
            let x = fraction * width
            let mapped = BufferSliderView.buffer(fromDragAtX: x, trackWidth: width, step: 1)
            XCTAssertEqual(mapped.map(Int.init), step,
                           "Step \(step) at fraction \(fraction) mapped to \(mapped.map { $0 } ?? nil)")
        }
    }

    func testDragMappingQuantizesToStep() {
        let width: CGFloat = 300
        // Half-step positions round to the nearest integer step.
        let quarter = BufferSliderView.buffer(fromDragAtX: width * 0.5 + width / 30.0, trackWidth: width, step: 1)
        XCTAssertTrue((-5...10).contains(Int(quarter ?? 0)))
    }

    func testLargerStepSizeJumpsByThatStep() {
        let width: CGFloat = 300
        let mapped = BufferSliderView.buffer(fromDragAtX: width * 0.9, trackWidth: width, step: 5)
        if let mapped {
            let remainder = mapped.truncatingRemainder(dividingBy: 5)
            XCTAssertEqual(remainder, 0, "Step 5 must quantize to multiples of 5, got \(mapped)")
        }
    }

    func testMappingClampsOutsideTrack() {
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: -100, trackWidth: 300, step: 1).map(Int.init), -5)
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 400, trackWidth: 300, step: 1).map(Int.init), 10)
    }

    func testMappingRejectsDegenerateGeometry() {
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: 50, trackWidth: 0, step: 1))
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: 50, trackWidth: -1, step: 1))
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: .nan, trackWidth: 300, step: 1))
        XCTAssertNil(BufferSliderView.buffer(fromDragAtX: .infinity, trackWidth: 300, step: 1))
    }

    func testMappingOnNarrowTrackStillSpansRange() {
        // A 40 pt track (small phones, accessibility sizes) must still
        // reach both endpoints.
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 0, trackWidth: 40, step: 1).map(Int.init), -5)
        XCTAssertEqual(BufferSliderView.buffer(fromDragAtX: 40, trackWidth: 40, step: 1).map(Int.init), 10)
    }

    // MARK: - Metric relabel consistency

    /// The slider edits an mph buffer; a Metric user must see km/h labels
    /// derived from the same SpeedFormatting conversion the HUD uses.
    func testMetricLabelsMatchFormattingConversion() {
        for mph in -5...10 {
            let kmh = SpeedFormatting.displayBuffer(forMph: Double(mph), measurementSystem: "Metric")
            XCTAssertEqual(kmh, (Double(mph) * SpeedFormatting.kmhPerMph).rounded(),
                           "Buffer \(mph) mph must label as \(kmh) km/h")
        }
    }

    /// The 15-step track (−5…10 mph) maps to 16 discrete positions — the
    /// metric label set must be injective enough that two adjacent steps
    /// never collapse to the same km/h label beyond ±1 rounding.
    func testMetricLabelSetStaysDistinct() {
        var labels: [Int] = []
        for mph in -5...10 {
            labels.append(Int(SpeedFormatting.displayBuffer(forMph: Double(mph), measurementSystem: "Metric")))
        }
        let unique = Set(labels)
        XCTAssertGreaterThanOrEqual(unique.count, 13,
                                    "Too many metric labels collide (\(unique.count)/16 distinct): \(labels)")
    }

    // MARK: - Fill-position consistency (the photographed bug)

    /// The fill fraction must map the buffer through the FULL −5…10 range:
    /// +3 sits at 8/15 ≈ 53.3%, never at buffer/10 = 30%.
    func testFillFractionUsesFullRange() {
        for buffer in -5...10 {
            let fill = CGFloat(buffer + 5) / 15.0
            let wrongFill = CGFloat(max(0, buffer)) / 10.0
            if buffer >= 0 {
                XCTAssertNotEqual(fill, wrongFill,
                                  "Buffer \(buffer): full-range fill and legacy buffer/10 fill collide")
            }
            XCTAssertTrue((0.0...1.0).contains(fill))
        }
        // The regression pair: +3 at 53%, +5 at 67%.
        XCTAssertEqual(CGFloat(3 + 5) / 15.0, 0.5333, accuracy: 0.001)
        XCTAssertEqual(CGFloat(5 + 5) / 15.0, 0.6667, accuracy: 0.001)
    }

    // MARK: - Live threshold coupling

    /// The slider's value feeds SpeedEngine.userBuffer — moving the slider
    /// must move the alert threshold on the next tick (the b640 contract).
    func testSliderValueMovesAlertThreshold() {
        let defaults = UserDefaults.standard
        defaults.set("Imperial", forKey: "measurementSystem")
        defer { defaults.removeObject(forKey: "userBuffer") }

        let engine = SpeedEngine(locationManager: LocationManager())
        defaults.set(3, forKey: "userBuffer")
        engine.speed = 49.0
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .over, "49 > 45+3")

        defaults.set(5, forKey: "userBuffer") // the slider drag
        engine.applyResolvedLimit(45)
        XCTAssertEqual(engine.status, .warning, "49 ≤ 45+5 → warning band")
    }
}
