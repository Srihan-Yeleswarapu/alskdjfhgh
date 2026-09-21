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
        let source = try readSource(carPlayUISourcePath())
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
        let source = try readSource(mapWithHUDSourcePath())
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
        let source = try readSource(carPlayTemplateSourcePath())
        XCTAssertTrue(
            source.contains("CarPlayUI.speedLimitSign(value: displayLimit, unit: unitShort"),
            "CarPlay's limit button must show the same shared MUTCD sign."
        )
        XCTAssertTrue(
            source.contains("limitButton.image = CarPlayUI.speedLimitSign(value: displayLimit, unit: unitShort"),
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

    /// The XCTest runner's cwd is the simulator's sandbox container, where
    /// the repo's relative source paths don't exist — anchor to this test
    /// file's absolute location in the host checkout instead:
    /// <repo root>/SmartSpeedCompanionTests/SpeedLimitSignTests.swift
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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

    private func readSource(_ path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            // The simulator's test host is sandboxed: macOS TCC denies reads of
            // ~/Documents, so the host checkout can't be inspected from there.
            // Skip (don't fail) — the pixel-geometry tests cover the rendered
            // output, and these source checks still run where reads are allowed.
            throw XCTSkip(
                "Repo source not readable from the test sandbox: \(error.localizedDescription)"
            )
        }
    }

    private func carPlayUISourcePath() -> String {
        Self.repoRoot.appendingPathComponent("SmartSpeedCompanion/CarPlay/CarPlayUI.swift").path
    }

    private func mapWithHUDSourcePath() -> String {
        Self.repoRoot.appendingPathComponent("SmartSpeedCompanion/Views/Drive/MapWithHUDView.swift").path
    }

    private func carPlayTemplateSourcePath() -> String {
        Self.repoRoot.appendingPathComponent("SmartSpeedCompanion/CarPlay/CarPlayNavigationRootTemplate.swift").path
    }
}

/// Pixel-level geometry regression for the R2-1 restyle. Two original bugs:
/// text was laid out in font line boxes, bunching ink at the top and leaving
/// a huge blank white bottom half (and the black border bled to the sign's
/// edge); then the first redraw drew a SQUARE badge with a chunky border and
/// small digits instead of the real R2-1 portrait plate. These tests render
/// the ACTUAL UIImage and measure where the ink really lands — against both
/// the centered-stack rules and the proportions measured off a real R2-1
/// reference (portrait 0.79 plate, ~3%-of-width border, 17.5% caption caps,
/// ~46% numeral caps) — so layout can never silently drift again.
final class SpeedLimitSignGeometryTests: XCTestCase {

    /// Anchor for repo-relative resources, mirroring SpeedLimitSignTests.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let renderSize: CGFloat = 120

    // MARK: - Ink map

    /// Luminance bitmap of a rendered sign plus row/column ink profiles.
    private struct InkMap {
        let pxWidth: Int
        let pxHeight: Int
        let scale: CGFloat
        private let dark: [Bool]
        private let alpha: [UInt8]

        init(image: UIImage) {
            let cg = try! XCTUnwrap(image.cgImage)
            pxWidth = cg.width
            pxHeight = cg.height
            scale = image.scale
            var pixels = [UInt8](repeating: 0, count: pxWidth * pxHeight * 4)
            let ctx = CGContext(
                data: &pixels,
                width: pxWidth,
                height: pxHeight,
                bitsPerComponent: 8,
                bytesPerRow: pxWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pxWidth, height: pxHeight))
            var darkMap = [Bool](repeating: false, count: pxWidth * pxHeight)
            var alphaMap = [UInt8](repeating: 0, count: pxWidth * pxHeight)
            for i in 0..<(pxWidth * pxHeight) {
                let r = Double(pixels[i * 4])
                let g = Double(pixels[i * 4 + 1])
                let b = Double(pixels[i * 4 + 2])
                let luminance = 0.299 * r + 0.587 * g + 0.114 * b
                darkMap[i] = luminance < 128 // sign black ≈ 15, face white ≈ 252
                alphaMap[i] = pixels[i * 4 + 3] // plate face vs transparent letterbox
            }
            dark = darkMap
            alpha = alphaMap
        }

        func isDark(x: Int, y: Int) -> Bool { dark[y * pxWidth + x] }
        func isOpaque(x: Int, y: Int) -> Bool { alpha[y * pxWidth + x] > 32 }
    }

    /// Bounds of all opaque pixels — i.e. the plate itself, since the
    /// portrait plate is letterboxed inside the square transparent canvas.
    private func plateBounds(in map: InkMap) -> CGRect {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<map.pxHeight {
            for x in 0..<map.pxWidth where map.isOpaque(x: x, y: y) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGRect(
            x: CGFloat(minX) / map.scale, y: CGFloat(minY) / map.scale,
            width: CGFloat(maxX - minX + 1) / map.scale,
            height: CGFloat(maxY - minY + 1) / map.scale
        )
    }

    /// Contiguous row bands containing ink, inside the inner face region
    /// (inset past rim + border so the frame itself is not measured).
    private func inkBands(in map: InkMap, minGapPx: Int = 4) -> [(top: Int, bottom: Int)] {
        let inset = Int((renderSize * 0.15) * map.scale)
        let x0 = inset, x1 = map.pxWidth - inset
        var rowHasInk = [Bool](repeating: false, count: map.pxHeight)
        for y in inset..<(map.pxHeight - inset) {
            for x in stride(from: x0, to: x1, by: 2) where map.isDark(x: x, y: y) {
                rowHasInk[y] = true
                break
            }
        }
        var bands: [(top: Int, bottom: Int)] = []
        var y = inset
        while y < map.pxHeight - inset {
            if rowHasInk[y] {
                let top = y
                while y < map.pxHeight - inset, rowHasInk[y] { y += 1 }
                bands.append((top, y - 1))
            } else {
                y += 1
            }
        }
        // Merge bands separated by less than minGapPx (anti-aliasing slivers).
        var merged: [(top: Int, bottom: Int)] = []
        for band in bands {
            if let last = merged.last, band.top - last.bottom < minGapPx {
                merged[merged.count - 1].bottom = band.bottom
            } else {
                merged.append(band)
            }
        }
        return merged
    }

    private func renderSign(value: Int?, unit: String?) -> InkMap {
        let image = CarPlayUI.speedLimitSign(value: value, unit: unit, size: renderSize)
        return InkMap(image: image)
    }

    // MARK: - Stack centering (the original bug)

    func testTextStackIsCenteredOnSignFace() {
        let map = renderSign(value: 30, unit: nil)
        let inset = Int((renderSize * 0.15) * map.scale)

        var firstRow = -1, lastRow = -1, firstCol = -1, lastCol = -1
        for y in inset..<(map.pxHeight - inset) {
            for x in inset..<(map.pxWidth - inset) where map.isDark(x: x, y: y) {
                if firstRow < 0 { firstRow = y }
                lastRow = y
                if firstCol < 0 || x < firstCol { firstCol = x }
                if x > lastCol { lastCol = x }
            }
        }
        XCTAssertGreaterThan(firstRow, 0, "Sign must contain ink inside the inner face region")

        let topMargin = firstRow - inset
        let bottomMargin = (map.pxHeight - inset) - lastRow
        let verticalSlack = abs(topMargin - bottomMargin)
        let tolerance = Int(renderSize * map.scale * 0.02) // 2% of sign size
        XCTAssertLessThanOrEqual(
            verticalSlack, tolerance,
            "SPEED/LIMIT/numeral stack must be vertically centered: " +
            "top margin \(topMargin)px vs bottom margin \(bottomMargin)px — " +
            "this is the top-heavy layout regression."
        )

        let leftMargin = firstCol - inset
        let rightMargin = (map.pxWidth - inset) - lastCol
        XCTAssertLessThanOrEqual(
            abs(leftMargin - rightMargin), tolerance,
            "Text stack must be horizontally centered: " +
            "left \(leftMargin)px vs right \(rightMargin)px."
        )
    }

    // MARK: - Placeholder dashes centered in the numeral slot

    func testPlaceholderDashesSitMidSlotLikeANumeral() {
        let digitMap = renderSign(value: 8, unit: nil)
        let dashMap = renderSign(value: nil, unit: nil)

        let digitBands = inkBands(in: digitMap)
        let dashBands = inkBands(in: dashMap)
        // SPEED, LIMIT, numeral — three distinct bands at this size.
        XCTAssertGreaterThanOrEqual(digitBands.count, 3, "Expected SPEED/LIMIT/numeral ink bands")
        XCTAssertEqual(dashBands.count, digitBands.count, "Placeholder must occupy the same slots as a numeral")

        let digitBand = digitBands.last!
        let dashBand = dashBands.last!
        let digitCenter = CGFloat(digitBand.top + digitBand.bottom) / 2
        let dashCenter = CGFloat(dashBand.top + dashBand.bottom) / 2
        let tolerance = renderSize * digitMap.scale * 0.015 // 1.5% of size
        XCTAssertLessThanOrEqual(
            abs(dashCenter - digitCenter), tolerance,
            "'--' must be vertically centered in the numeral slot, not pinned to its top: " +
            "dash center \(dashCenter)px vs digit center \(digitCenter)px."
        )

        let digitHeight = digitBand.bottom - digitBand.top
        let dashHeight = dashBand.bottom - dashBand.top
        XCTAssertLessThan(
            CGFloat(dashHeight), CGFloat(digitHeight) * 0.75,
            "Hyphen ink must be much shorter than digit ink — sanity check that we compared '--' with a digit."
        )
    }

    // MARK: - R2-1 plate geometry (measured off the reference blank)

    func testPlateIsPortraitWithThinBorderLikeTheRealSign() {
        let map = renderSign(value: 55, unit: nil)
        let plate = plateBounds(in: map)

        // The 24"×30" regulatory blank: portrait, W/H ≈ 0.79 — NOT the
        // square badge the first redraw produced.
        XCTAssertLessThan(plate.width, plate.height, "R2-1 is a portrait plate.")
        XCTAssertEqual(plate.width / plate.height, 0.79, accuracy: 0.03)
        // Letterboxed in the square canvas: real side margins must exist.
        XCTAssertEqual(plate.minX, (renderSize - plate.width) / 2, accuracy: 1.0)

        // Border thickness: walk the horizontal centerline from the plate's
        // left edge — a white margin, then the black border run.
        let midY = Int(round(plate.midY * map.scale))
        var x = Int(round(plate.minX * map.scale))
        while x < map.pxWidth, !map.isDark(x: x, y: midY) { x += 1 }
        var blackRun = 0
        while x < map.pxWidth, map.isDark(x: x, y: midY) { blackRun += 1; x += 1 }
        let borderFraction = CGFloat(blackRun) / map.scale / plate.width
        XCTAssertEqual(
            borderFraction, 0.030, accuracy: 0.012,
            "The border must be the thin ~3%-of-width regulatory rule hugging " +
            "the edge, not the chunky frame+rim of the badge design."
        )
    }

    func testCaptionAndNumeralMatchReferenceTypeScale() {
        let map = renderSign(value: 55, unit: nil)
        let plate = plateBounds(in: map)
        let bands = inkBands(in: map, minGapPx: 4)
        // SPEED, LIMIT, numeral — three distinct bands at this size.
        XCTAssertEqual(bands.count, 3, "Expected exactly SPEED/LIMIT/numeral ink bands")

        let bandFraction = { (band: (top: Int, bottom: Int)) in
            CGFloat(band.bottom - band.top + 1) / map.scale / plate.width
        }
        XCTAssertEqual(
            bandFraction(bands[0]), 0.175, accuracy: 0.03,
            "SPEED caps must be ≈17.5% of plate width, as measured on the reference."
        )
        XCTAssertEqual(
            bandFraction(bands[1]), 0.175, accuracy: 0.03,
            "LIMIT caps must match SPEED."
        )
        XCTAssertEqual(
            bandFraction(bands[2]), 0.46, accuracy: 0.05,
            "The numeral must dominate the face (≈46% of plate width, like the " +
            "real sign) — the badge design's ~24% digits were unreadable at " +
            "CarPlay sizes."
        )
    }
}
