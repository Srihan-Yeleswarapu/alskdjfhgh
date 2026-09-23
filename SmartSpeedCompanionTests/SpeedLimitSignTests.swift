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
        )            // MUTCD R2-1 is black-on-white — no red ring, no colored face.
            XCTAssertTrue(source.contains("signBlack"), "The sign border/caption/numeral must be black.")
            XCTAssertTrue(source.contains("signWhite"), "The sign face must be white.")
            // The Highway Gothic descendant bundled with the app.
            XCTAssertTrue(
                source.contains("Overpass-Bold"),
                "The sign must draw with the bundled Overpass Bold (Highway Gothic descendant)."
            )
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

/// Pixel-level geometry regression for the R2-1 restyle. Original bugs:
/// text was laid out in font line boxes (bunching ink at the top), then a
/// square badge with a chunky border and small digits replaced the real
/// sign. The current design is the user-approved HTML replica
/// (`speed-limit-sign.html`), pixel-measured from a real R2-1 photo.
/// These tests render the ACTUAL UIImage and measure where the ink really
/// lands against that approved spec — 1000×1250 sheet, 10-unit white
/// margin, 28-unit border, caption ink widths 800/611, numeral 750 wide —
/// so the app can never silently drift from what was approved.
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
        let plate = plateBounds(in: map)
        let plateLeftPx = Int(round(plate.minX * map.scale))
        let plateRightPx = Int(round(plate.maxX * map.scale))

        var firstRow = -1, lastRow = -1, firstCol = -1, lastCol = -1
        for y in 0..<map.pxHeight {
            for x in plateLeftPx...plateRightPx where map.isDark(x: x, y: y)
                && x > plateLeftPx + 2 && x < plateRightPx - 2 { // skip the border stroke
                if firstRow < 0 { firstRow = y }
                lastRow = y
                if firstCol < 0 || x < firstCol { firstCol = x }
                if x > lastCol { lastCol = x }
            }
        }
        XCTAssertGreaterThan(firstRow, 0, "Sign must contain legend ink inside the plate")

        // Legend vertical centering is measured against the plate itself
        // (its top/bottom rounded corner arcs dip 1-3px below the exact
        // midline scan line, so ±3px is the honest tolerance).
        let topMargin = firstRow - Int(round(plate.minY * map.scale))
        let bottomMargin = Int(round(plate.maxY * map.scale)) - lastRow
        let verticalSlack = abs(topMargin - bottomMargin)
        XCTAssertLessThanOrEqual(
            verticalSlack, 3,
            "SPEED/LIMIT/numeral stack must be vertically centered on the plate: " +
            "top margin \(topMargin)px vs bottom margin \(bottomMargin)px — " +
            "this is the top-heavy layout regression."
        )

        let leftMargin = firstCol - plateLeftPx
        let rightMargin = plateRightPx - lastCol
        XCTAssertLessThanOrEqual(
            abs(leftMargin - rightMargin), 2,
            "Text stack must be horizontally centered on the plate: " +
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
            "Dash ink must be much shorter than digit ink — sanity check that we compared '--' with a digit."
        )
    }

    // MARK: - R2-1 plate geometry (approved HTML replica spec)

    func testPlateIsPortraitWithThinBorderLikeTheRealSign() {
        let map = renderSign(value: 55, unit: nil)
        let plate = plateBounds(in: map)

        // The 1000×1250 regulatory blank: portrait, aspect 0.8 — NOT the
        // square badge the first redraw produced.
        XCTAssertLessThan(plate.width, plate.height, "R2-1 is a portrait plate.")
        XCTAssertEqual(plate.width / plate.height, 0.8, accuracy: 0.03)
        // Letterboxed in the square canvas: real side margins must exist.
        XCTAssertEqual(plate.minX, (renderSize - plate.width) / 2, accuracy: 1.0)

        // Border thickness: walk the horizontal centerline from the plate's
        // left edge — a white margin, then the black border run. The spec's
        // 28-unit rule is 2.8% of the 1000-unit sheet width.
        let midY = Int(round(plate.midY * map.scale))
        var x = Int(round(plate.minX * map.scale))
        while x < map.pxWidth, !map.isDark(x: x, y: midY) { x += 1 }
        var blackRun = 0
        while x < map.pxWidth, map.isDark(x: x, y: midY) { blackRun += 1; x += 1 }
        let borderFraction = CGFloat(blackRun) / map.scale / plate.width
        XCTAssertEqual(
            borderFraction, 0.028, accuracy: 0.012,
            "The border must be the thin 2.8%-of-width regulatory rule hugging " +
            "the edge (28 units of the 1000-unit sheet), not the chunky " +
            "frame+rim of the badge design."
        )
    }

    func testCaptionAndNumeralMatchReferenceTypeScale() {
        let map = renderSign(value: 55, unit: nil)
        let plate = plateBounds(in: map)
        let bands = inkBands(in: map, minGapPx: 4)
        // SPEED, LIMIT, numeral — three distinct bands at this size.
        XCTAssertEqual(bands.count, 3, "Expected exactly SPEED/LIMIT/numeral ink bands")

        // Column ink extents of a band (used for the ink-width checks).
        let bandExtent = { (band: (top: Int, bottom: Int)) -> (left: Int, right: Int) in
            let inset = Int((self.renderSize * 0.15) * map.scale)
            var left = Int.max, right = -1
            for y in band.top...band.bottom {
                for x in stride(from: inset, to: map.pxWidth - inset, by: 1) where map.isDark(x: x, y: y) {
                    left = min(left, x); right = max(right, x)
                }
            }
            return (left, right)
        }
        let inkWidthFraction = { (band: (top: Int, bottom: Int)) -> CGFloat in
            let extent = bandExtent(band)
            return CGFloat(extent.right - extent.left + 1) / map.scale / plate.width
        }

        // Cap bands: 171/1000 ≈ 17.1% of sheet width, as measured.
        XCTAssertEqual(
            CGFloat(bands[0].bottom - bands[0].top + 1) / map.scale / plate.width,
            0.171, accuracy: 0.03,
            "SPEED caps must be ≈17.1% of sheet width, as measured on the reference."
        )
        XCTAssertEqual(
            CGFloat(bands[1].bottom - bands[1].top + 1) / map.scale / plate.width,
            0.171, accuracy: 0.03,
            "LIMIT caps must match SPEED."
        )
        XCTAssertEqual(
            CGFloat(bands[2].bottom - bands[2].top + 1) / map.scale / plate.width,
            0.436, accuracy: 0.04,
            "The numeral must dominate the face (≈43.6% of sheet width) — the " +
            "badge design's ~24% digits were unreadable at CarPlay sizes."
        )

        // Ink WIDTHS (the fit() solve's contract): SPEED 800/1000,
        // LIMIT 611/1000, numeral 750/1000 of the sheet.
        XCTAssertEqual(
            inkWidthFraction(bands[0]), 0.800, accuracy: 0.05,
            "SPEED ink must span ≈80% of the sheet width — the approved " +
            "caption width from the measured reference."
        )
        XCTAssertEqual(
            inkWidthFraction(bands[1]), 0.611, accuracy: 0.05,
            "LIMIT ink must span ≈61% of the sheet width."
        )
        XCTAssertEqual(
            inkWidthFraction(bands[2]), 0.750, accuracy: 0.06,
            "The numeral ink must span ≈75% of the sheet width."
        )
    }
}
