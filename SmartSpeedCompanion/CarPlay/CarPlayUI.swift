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
    /// Geometry follows MUTCD R2-1 proportions adapted to a square canvas:
    /// ~12% corner rounding, a white rim OUTSIDE a ~5%-of-width black border
    /// (like the stamped aluminum blank), and a SPEED / LIMIT + numeral stack
    /// centered as one block so the face is never top- or bottom-heavy.
    static func speedLimitSign(value: Int?, unit: String?, size: CGFloat) -> UIImage {
        let size = max(24, size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let cornerRadius = size * 0.12

            // White face, then the black regulatory border inset from the
            // edge so a thin white rim stays visible outside it — exactly
            // like the real R2-1 blank. The stroke is centered on its path,
            // so inset by rim + half the border width.
            let rim = size * 0.045
            let borderWidth = size * 0.05
            signWhite.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).fill()
            signBlack.setStroke()
            let borderInset = rim + borderWidth / 2
            let border = UIBezierPath(
                roundedRect: rect.insetBy(dx: borderInset, dy: borderInset),
                cornerRadius: cornerRadius * 0.82
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
            let captionKern = size * 0.015
            let captionFont = UIFont.systemFont(ofSize: size * 0.155, weight: .heavy)
            let numeralFont = UIFont.systemFont(ofSize: showUnit ? size * 0.34 : size * 0.44, weight: .black)
            let unitFont = UIFont.systemFont(ofSize: size * 0.105, weight: .heavy)

            let captionInk = captionFont.capHeight
            let numeralInk = numeralFont.capHeight
            let unitInk = unitFont.capHeight
            let captionGap = size * 0.020   // SPEED ↔ LIMIT
            let numeralGap = size * 0.032   // LIMIT ↔ numeral
            let unitGap = showUnit ? size * 0.012 : 0

            let stackHeight = captionInk + captionGap + captionInk
                + numeralGap + numeralInk + unitGap + (showUnit ? unitInk : 0)
            let stackTop = (size - stackHeight) / 2

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
                ctx?.textPosition = CGPoint(x: (size - inkWidth) / 2, y: size - baselineFromTop)
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
