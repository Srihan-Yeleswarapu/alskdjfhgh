import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for the speed-limit sign restyle: the HUD previously
/// drew a UK/Vienna-style white circle with a red ring, but the product now
/// shows the US MUTCD R2-1 regulatory sign (white face, thick black border,
/// "SPEED LIMIT" caption, black numeral) on BOTH the iPhone HUD and CarPlay.
///
/// The single renderer is `CarPlayUI.speedLimitSign(value:unit:size:)` — the
/// phone's `LimitSignView` and CarPlay's `limitButton` both consume it, so
/// the two surfaces cannot drift apart.
final class SpeedLimitSignTests: XCTestCase {

    // MARK: - Shared renderer

    func testSharedRendererDrawsMUTCDStyleSign() throws {
        let source = try String(contentsOfFile: carPlayUISourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("static func speedLimitSign(value: Int?, unit: String?, size: CGFloat) -> UIImage"),
            "The sign must be rendered by one shared function consumed by both phone and CarPlay."
        )
        // MUTCD R2-1 is black-on-white — no red ring, no colored face.
        XCTAssertTrue(source.contains("signBlack"), "The sign border/caption/numeral must be black.")
        XCTAssertTrue(source.contains("signWhite"), "The sign face must be white.")
        // Caption words of the real sign.
        XCTAssertTrue(source.contains("\"SPEED\""), "The sign must caption SPEED.")
        XCTAssertTrue(source.contains("\"LIMIT\""), "The sign must caption LIMIT.")
        // Unknown limits render as "--" instead of dropping the sign.
        let body = try sourceSection(in: source, anchor: "static func speedLimitSign(")
        XCTAssertTrue(body.contains("\"--\""), "A missing/zero limit must render as '--', not a blank sign.")
    }

    // MARK: - iPhone HUD

    func testPhoneLimitSignUsesSharedRendererNotRedCircle() throws {
        let source = try String(contentsOfFile: mapWithHUDSourcePath(), encoding: .utf8)
        let signBody = try sourceSection(in: source, anchor: "fileprivate struct LimitSignView")
        XCTAssertTrue(
            signBody.contains("CarPlayUI.speedLimitSign("),
            "LimitSignView must render through the shared renderer so phone and CarPlay match."
        )
        XCTAssertFalse(
            signBody.contains("#FF3D71"),
            "The UK-style red-ring circle must be gone from the limit sign."
        )
        XCTAssertFalse(
            signBody.contains("Circle()"),
            "The sign face must be the rectangular MUTCD sign, not a circle."
        )
        // Tap-to-refresh and the source chip survive the restyle.
        XCTAssertTrue(signBody.contains("Tap to refresh"), "Tap-to-refresh affordance must be preserved.")
        XCTAssertTrue(signBody.contains("sourceChip"), "The limit-source chip must be preserved.")
    }

    // MARK: - CarPlay

    func testCarPlayLimitButtonRendersSignImage() throws {
        let source = try String(contentsOfFile: carPlayTemplateSourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("CarPlayUI.speedLimitSign(value: displayLimit, unit: unitShort"),
            "CarPlay's limit button must show the same shared MUTCD sign."
        )
        XCTAssertTrue(
            source.contains("limitButton.image = sign"),
            "The sign must be set as the button image."
        )
        XCTAssertFalse(
            source.contains("limitButton.title = limit == 0"),
            "The old text-only 'LIMIT 65 MPH' button must be gone."
        )
        // The ~1 Hz HUD tick must not re-render the UIKit sign every second.
        XCTAssertTrue(
            source.contains("lastRenderedSignLimit"),
            "Sign rendering must be cached by displayed value, not redrawn every HUD tick."
        )
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n    }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func carPlayUISourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayUI.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayUI.swift"
        #endif
    }

    private func mapWithHUDSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Views\\Drive\\MapWithHUDView.swift"
        #else
        return "SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift"
        #endif
    }

    private func carPlayTemplateSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\CarPlay\\CarPlayNavigationRootTemplate.swift"
        #else
        return "SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift"
        #endif
    }
}
