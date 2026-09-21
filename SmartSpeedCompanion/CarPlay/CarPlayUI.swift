// CarPlayUI.swift
// =================================
// Shared visual design system for the Speedio CarPlay experience.
// Provides the canonical palette (mirroring DesignSystem on the
// phone) and rendered icon assets — iOS-Settings-style colored
// tiles, circular map-button badges, HUD status pills — so every
// CarPlay screen shares one cohesive, premium look.

import UIKit

enum CarPlayUI {

    // MARK: - Palette (mirrors DesignSystem)

    static let cyan      = UIColor(red: 0.000, green: 0.831, blue: 1.000, alpha: 1.0) // #00D4FF
    static let neonGreen = UIColor(red: 0.000, green: 1.000, blue: 0.616, alpha: 1.0) // #00FF9D
    static let amber     = UIColor(red: 1.000, green: 0.722, blue: 0.000, alpha: 1.0) // #FFB800
    static let alertRed  = UIColor(red: 1.000, green: 0.239, blue: 0.443, alpha: 1.0) // #FF3D71
    static let blue      = UIColor(red: 0.039, green: 0.518, blue: 1.000, alpha: 1.0) // #0A84FF
    static let purple    = UIColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1.0) // #BF5AF2
    static let orange    = UIColor(red: 1.000, green: 0.624, blue: 0.039, alpha: 1.0) // #FF9F0A
    static let teal      = UIColor(red: 0.251, green: 0.784, blue: 0.878, alpha: 1.0) // #40C8E0
    static let pink      = UIColor(red: 1.000, green: 0.216, blue: 0.373, alpha: 1.0) // #FF375F
    static let indigo    = UIColor(red: 0.369, green: 0.361, blue: 0.902, alpha: 1.0) // #5E5CE6
    static let gray      = UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0) // #8E8E93

    /// Liquid-glass guidance panel tone for the map template's
    /// `guidanceBackgroundColor`. CarPlay's default is a solid red banner
    /// above the map; this replaces it with the same dark translucent glass
    /// material the system uses for the trip-estimates panel (bottom-left
    /// distance / time / ETA), so all guidance chrome reads as one material.
    /// The alpha is intentional — CarPlay composites the guidance background
    /// over the live map for a glass-like translucency; head units that
    /// flatten it still render the same charcoal glass tone. The tone is
    /// dark, so white instruction text clears the system's contrast check
    /// (the documented fallback would otherwise restore the default red).

    static let guidanceGlass = UIColor(white: 0.10, alpha: 0.80)

    /// Canonical status color used across the HUD and alerts.
    static func statusColor(_ status: SpeedStatus) -> UIColor {
        switch status {
        case .safe:    return neonGreen
        case .warning: return amber
        case .over:    return alertRed
        }
    }

    // MARK: - Renderers

    /// Renders an SF Symbol as an `alwaysOriginal` (full-color) image.
    private static func symbol(_ name: String,
                               pointSize: CGFloat,
                               weight: UIImage.SymbolWeight = .semibold,
                               color: UIColor = .white) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// iOS Settings-style colored rounded-square tile with a white glyph.
    /// Used for list-row icons across settings, profiles, and places.
    static func iconTile(systemName: String,
                         color: UIColor,
                         size: CGFloat = 44,
                         cornerRatio: CGFloat = 0.225,
                         symbolSize: CGFloat? = nil) -> UIImage {
        let glyph = symbolSize ?? size * 0.5
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * cornerRatio)
            color.setFill()
            path.fill()
            if let s = symbol(systemName, pointSize: glyph) {
                s.draw(in: CGRect(x: (size - s.size.width) / 2,
                                  y: (size - s.size.height) / 2,
                                  width: s.size.width,
                                  height: s.size.height))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Circular colored badge with a white glyph — the map-button look.
    /// Renders full-color so the buttons read like Google/Apple Maps
    /// action buttons instead of flat system glyphs.
    static func circleBadge(systemName: String,
                            color: UIColor,
                            size: CGFloat = 46,
                            symbolSize: CGFloat? = nil) -> UIImage {
        let glyph = symbolSize ?? size * 0.52
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
            if let s = symbol(systemName, pointSize: glyph) {
                s.draw(in: CGRect(x: (size - s.size.width) / 2,
                                  y: (size - s.size.height) / 2,
                                  width: s.size.width,
                                  height: s.size.height))
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Capsule-shaped status indicator for the HUD limit button.
    static func statusPill(color: UIColor,
                           size: CGSize = CGSize(width: 44, height: 22)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size.height / 2)
            color.setFill()
            path.fill()
            // Thin white border for definition against the map.
            UIColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Small solid dot — used as the recording indicator.
    static func dot(color: UIColor, size: CGFloat = 14) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let path = UIBezierPath(ovalIn: rect)
            color.setFill()
            path.fill()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Speed Limit Sign (US MUTCD R2-1 style)

    /// Colors of the US regulatory speed-limit sign (MUTCD R2-1): white
    /// face, black border, black caption + numeral. US signs are
    /// black-on-white with no red ring — the red-ring circle is the
    /// Vienna/UK convention the HUD previously used.
    private static let signBlack = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
    private static let signWhite = UIColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1)

    /// Draws the US-style speed-limit sign at any size. Both the phone HUD
    /// (`LimitSignView`) and the CarPlay limit button render through this
    /// single function so the two surfaces can never drift apart.
    ///
    /// Geometry is measured off a real MUTCD R2-1 reference photo, not
    /// eyeballed: a PORTRAIT plate with W/H ≈ 0.79 (the standard 24"×30"
    /// blank), a thin ~3%-of-width black border hugging the edge with only a
    /// hairline white margin outside it, tight ~4% corners, and a
    /// SPEED / LIMIT + numeral stack that nearly fills the face. The portrait
    /// plate is letterboxed inside the square canvas (both call sites frame
    /// the image square), so its proportions render true and the side margins
    /// stay transparent.
    static func speedLimitSign(value: Int?, unit: String?, size: CGFloat) -> UIImage {
        let size = max(24, size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { _ in
            /// Visible ink width of a line: CoreText typographic bounds
            /// minus the trailing kern (kern trails the last glyph, adding
            /// one phantom space to the measured width).
            func inkedWidth(_ text: String, font: UIFont, kern: CGFloat) -> CGFloat {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                return max(0, width - kern)
            }

            // --- Plate blank (all fractions below are of the plate's WIDTH) ---
            let aspect: CGFloat = 0.79           // W/H of the 24"×30" plate
            let canvasInset = size * 0.01        // keep AA edges off canvas bounds
            let signH = size - canvasInset * 2
            let signW = signH * aspect
            let signRect = CGRect(x: (size - signW) / 2, y: canvasInset, width: signW, height: signH)
            let cornerRadius = signW * 0.04      // tight corners, as measured
            let edgeMargin = signW * 0.016       // white margin outside the border
            let borderWidth = signW * 0.030      // thin regulatory border

            signWhite.setFill()
            UIBezierPath(roundedRect: signRect, cornerRadius: cornerRadius).fill()
            signBlack.setStroke()
            let borderInset = edgeMargin + borderWidth / 2
            let border = UIBezierPath(
                roundedRect: signRect.insetBy(dx: borderInset, dy: borderInset),
                cornerRadius: max(signW * 0.01, cornerRadius - borderInset)
            )
            border.lineWidth = borderWidth
            border.stroke()

            // The white face the legend is laid out into (inside the border).
            let faceRect = signRect.insetBy(dx: borderInset + borderWidth / 2,
                                            dy: borderInset + borderWidth / 2)

            let numeral: String
            if let v = value, v > 0 {
                numeral = "\(v)"
            } else {
                numeral = "--"
            }
            // Real US signs carry no unit ("35", never "35 MPH"). Metric
            // signs (km/h) do, and metric users here historically needed the
            // disambiguation — so the unit is drawn for anything but MPH.
            let showUnit = numeral != "--"
                && unit?.isEmpty == false
                && unit?.uppercased() != "MPH"

            // Layout is done in INK coordinates, not font line boxes: each
            // line is placed by its capHeight (the actual black glyph area),
            // via CoreText baseline positioning. This keeps the stack truly
            // centered regardless of font line-height padding quirks.
            //
            // Type scale comes off the measured reference plate: caption
            // caps ≈ 17.5% of the plate width, numeral caps ≈ 46% (38% when
            // a unit line shares the face). SF Pro's cap height is ~0.714 em
            // across weights, which converts cap heights into point sizes.
            let capRatio: CGFloat = 0.714
            let captionCap = signW * 0.175
            let numeralCap = signW * (showUnit ? 0.38 : 0.48)
            let unitCap = signW * 0.12
            let captionKern = signW * 0.022
            let numeralKern = signW * 0.055   // the real plate tracks digits wide
            let unitKern = signW * 0.02
            let captionGap = signW * 0.068    // SPEED ↔ LIMIT
            let numeralGap = signW * 0.068    // LIMIT ↔ numeral
            let unitGap = showUnit ? signW * 0.025 : 0

            let captionFont = UIFont.systemFont(ofSize: captionCap / capRatio, weight: .heavy)
            let unitFont = UIFont.systemFont(ofSize: unitCap / capRatio, weight: .heavy)

            // Keep the numeral inside the face: two digits fit at the
            // reference scale, but 3-digit limits would overflow — rescale
            // once, exactly (font metrics are linear in size).
            let baseNumeralSize = numeralCap / capRatio
            let probeWidth = inkedWidth(
                numeral,
                font: UIFont.systemFont(ofSize: baseNumeralSize, weight: .black),
                kern: numeralKern
            )
            let maxNumeralWidth = faceRect.width * 0.92
            let numeralSize = probeWidth > maxNumeralWidth
                ? baseNumeralSize * maxNumeralWidth / probeWidth
                : baseNumeralSize
            let numeralFont = UIFont.systemFont(ofSize: numeralSize, weight: .black)

            let numeralInk = numeralSize * capRatio
            let stackHeight = captionCap + captionGap + captionCap
                + numeralGap + numeralInk + unitGap + (showUnit ? unitCap : 0)
            let stackTop = faceRect.minY + (faceRect.height - stackHeight) / 2

            /// Draws one line horizontally centered with the TOP of its
            /// glyph ink (the actual black area) at `inkTop`. CoreText
            /// positions from the baseline, so the baseline is derived from
            /// the line's measured ink span; the CT y-up flip puts it at
            /// `size - baseline`.
            /// When `slotInk` is given (the "--" placeholder), the line's ink
            /// is centered inside the [inkTop, inkTop + slotInk] band instead
            /// of pinned to the cap line — hyphens are only ~30% of cap
            /// height, so top-pinning would hug them to the slot's top.
            func drawInk(_ text: String, font: UIFont, inkTop: CGFloat, kern: CGFloat = 0, centerInSlotOf slotInk: CGFloat? = nil) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

                // Measure the line's ink span above the baseline from its
                // own glyph bounding boxes (digits/caps top out at cap
                // height; hyphens are much shorter). Falls back to the
                // font's cap height if measurement ever fails.
                var inkTopAboveBaseline = font.capHeight
                var inkBottomAboveBaseline: CGFloat = 0
                let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
                var measuredAnyGlyph = false
                var maxAbove = -CGFloat.greatestFiniteMagnitude
                var minAbove = CGFloat.greatestFiniteMagnitude
                for run in runs {
                    let count = CTRunGetGlyphCount(run)
                    guard count > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                    var bounds = [CGRect](repeating: .zero, count: count)
                    // UIFont toll-free-bridges to CTFont; the font passed
                    // in IS the one attached to the string, so measure with
                    // its actual weight.
                    CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, count)
                    for b in bounds {
                        measuredAnyGlyph = true
                        maxAbove = max(maxAbove, b.maxY)
                        minAbove = min(minAbove, b.minY)
                    }
                }
                if measuredAnyGlyph, maxAbove > minAbove {
                    inkTopAboveBaseline = maxAbove
                    inkBottomAboveBaseline = minAbove
                }

                let baselineFromTop: CGFloat
                if let slotInk {
                    let inkHeight = inkTopAboveBaseline - inkBottomAboveBaseline
                    baselineFromTop = inkTop + (slotInk - inkHeight) / 2 + inkTopAboveBaseline
                } else {
                    baselineFromTop = inkTop + inkTopAboveBaseline
                }

                // Kern trails the final glyph too, so the typographic width
                // carries one extra trailing space — subtract it so the
                // visible ink is what gets centered, not ink + padding.
                let inkWidth = max(0, lineWidth - kern)
                let ctx = UIGraphicsGetCurrentContext()
                ctx?.saveGState()
                ctx?.textMatrix = .identity
                ctx?.translateBy(x: 0, y: size)
                ctx?.scaleBy(x: 1, y: -1)
                // Center on the white FACE (inside the border), not the
                // canvas — the plate is letterboxed inside a square image.
                ctx?.textPosition = CGPoint(x: faceRect.midX - inkWidth / 2, y: size - baselineFromTop)
                CTLineDraw(line, ctx!)
                ctx?.restoreGState()
            }

            drawInk("SPEED", font: captionFont, inkTop: stackTop, kern: captionKern)
            drawInk("LIMIT", font: captionFont, inkTop: stackTop + captionCap + captionGap, kern: captionKern)
            let numeralTop = stackTop + captionCap + captionGap + captionCap + numeralGap
            let isPlaceholder = numeral == "--"
            drawInk(numeral, font: numeralFont, inkTop: numeralTop, kern: numeralKern,
                    centerInSlotOf: isPlaceholder ? numeralInk : nil)
            if showUnit, let unit {
                drawInk(unit, font: unitFont, inkTop: numeralTop + numeralInk + unitGap, kern: unitKern)
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
