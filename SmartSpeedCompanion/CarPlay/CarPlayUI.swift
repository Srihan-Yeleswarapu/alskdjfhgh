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
    private static let signBlack = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
    private static let signWhite = UIColor(red: 0.99, green: 0.99, blue: 0.98, alpha: 1)

    /// Aspect of the standard R2-1 blank: an 18" × 24" panel, so the drawn
    /// sign is PORTRAIT — height = 4/3 × width. The earlier renderer drew a
    /// square, which crushed the SPEED LIMIT stack and starved the numeral;
    /// the real sign (and the product reference) is taller than wide.
    static let signAspect: CGFloat = 4.0 / 3.0

    /// Draws the US-style speed-limit sign at any size. Both the phone HUD
    /// (`LimitSignView`) and the CarPlay limit button render through this
    /// single function so the two surfaces can never drift apart.
    ///
    /// `size` is the sign's WIDTH in points; the returned image measures
    /// `size` × `size * signAspect` (portrait, per the 18×24 blank).
    ///
    /// Geometry matches the MUTCD R2-1 blank (proportions measured off the
    /// product reference, as fractions of sign width): ~4.5% corner
    /// rounding, a ~3.5%-of-width black border sitting at the panel edge,
    /// and a vertically centered SPEED / LIMIT + numeral stack whose
    /// caption ink is ~17.5% of width and whose numeral ink fills ~48% of
    /// width — the dominant numeral is what makes the sign read correctly
    /// at HUD sizes. Numerals wider than ~80% of the sign width (3-digit
    /// limits) are scaled down to fit, mirroring how real blanks widen
    /// the panel instead.
    static func speedLimitSign(value: Int?, unit: String?, size: CGFloat) -> UIImage {
        let width = max(24, size)
        let height = width * signAspect
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let cornerRadius = width * 0.045

            // White face, then the black regulatory border right at the
            // panel edge (a hairline white rim keeps the anti-aliased
            // corners clean, matching the real blank). The stroke is
            // centered on its path, so inset by rim + half the border.
            let rim = width * 0.015
            let borderWidth = width * 0.036
            signWhite.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()
            signBlack.setStroke()
            let borderInset = rim + borderWidth / 2
            let border = UIBezierPath(
                roundedRect: rect.insetBy(dx: borderInset, dy: borderInset),
                cornerRadius: cornerRadius * 0.85
            )
            border.lineWidth = borderWidth
            border.stroke()

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
            // Ink targets come from the R2-1 reference (fractions of WIDTH):
            // captions 17.5%, numeral 47.5% (36% when the km/h unit shows).
            // Point sizes are DERIVED from the font's measured cap-height
            // ratio so the ink heights stay exact even if Apple tunes SF's
            // metrics.
            func fontForInk(_ ink: CGFloat, weight: UIFont.Weight) -> UIFont {
                let probe = UIFont.systemFont(ofSize: 100, weight: weight)
                let capRatio = probe.capHeight / 100
                return UIFont.systemFont(ofSize: ink / capRatio, weight: weight)
            }
            let captionInkTarget = width * 0.175
            let numeralInkTarget = showUnit ? width * 0.36 : width * 0.475
            let unitInkTarget = width * 0.105
            let captionKern = width * 0.015
            let captionFont = fontForInk(captionInkTarget, weight: .heavy)
            let unitFont = fontForInk(unitInkTarget, weight: .heavy)

            // The numeral is sized by ink HEIGHT first, then fitted by WIDTH:
            // two digits at the reference size nearly fill the face, so a
            // 3-digit limit (100–120 km/h) would overflow the border. Real
            // R2-1 blanks solve that by switching to a wider panel (24×30);
            // a fixed-aspect image shrinks the point size instead so the
            // ink never exceeds ~84% of the sign width — just above the
            // reference blank's own two-digit numeral (~79.6%W) so normal
            // limits render at exact reference size, while 3-digit values
            // (~1.2×W wide) still scale down to fit.
            func inkAdvanceWidth(_ text: String, font: UIFont) -> CGFloat {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font])
                )
                return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
            let numeralFont0 = fontForInk(numeralInkTarget, weight: .black)
            let maxNumeralInkWidth = width * 0.84
            let rawNumeralWidth = inkAdvanceWidth(numeral, font: numeralFont0)
            let numeralFont: UIFont
            if rawNumeralWidth > maxNumeralInkWidth, rawNumeralWidth > 0 {
                numeralFont = UIFont.systemFont(
                    ofSize: numeralFont0.pointSize * maxNumeralInkWidth / rawNumeralWidth,
                    weight: .black
                )
            } else {
                numeralFont = numeralFont0
            }

            let captionInk = captionFont.capHeight
            let numeralInk = numeralFont.capHeight
            let unitInk = unitFont.capHeight
            let captionGap = width * 0.112   // SPEED ↔ LIMIT (measured ~11%W)
            let numeralGap = width * 0.104   // LIMIT ↔ numeral (measured ~10.5%W)
            let unitGap = showUnit ? width * 0.025 : 0

            // The stack is centered in the face region BETWEEN the top and
            // bottom borders (border spans rim..rim+borderWidth from each
            // edge), matching how the reference blank distributes its text.
            let stackHeight = captionInk + captionGap + captionInk
                + numeralGap + numeralInk + unitGap + (showUnit ? unitInk : 0)
            let faceTop = rim + borderWidth
            let faceBottom = height - rim - borderWidth
            let stackTop = faceTop + (faceBottom - faceTop - stackHeight) / 2

            /// Draws one line horizontally centered with the TOP of its
            /// glyph ink (the actual black area) at `inkTop`. CoreText
            /// positions from the baseline, so the baseline is derived from
            /// the line's measured ink span; the CT y-up flip puts it at
            /// `height - baseline`.
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
                ctx?.translateBy(x: 0, y: height)
                ctx?.scaleBy(x: 1, y: -1)
                ctx?.textPosition = CGPoint(x: (width - inkWidth) / 2, y: height - baselineFromTop)
                CTLineDraw(line, ctx!)
                ctx?.restoreGState()
            }

            drawInk("SPEED", font: captionFont, inkTop: stackTop, kern: captionKern)
            drawInk("LIMIT", font: captionFont, inkTop: stackTop + captionInk + captionGap, kern: captionKern)
            let numeralTop = stackTop + captionInk + captionGap + captionInk + numeralGap
            let isPlaceholder = numeral == "--"
            drawInk(numeral, font: numeralFont, inkTop: numeralTop,
                    centerInSlotOf: isPlaceholder ? numeralInk : nil)
            if showUnit, let unit {
                drawInk(unit, font: unitFont, inkTop: numeralTop + numeralInk + unitGap)
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
