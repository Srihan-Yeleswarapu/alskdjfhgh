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

    /// Colors sampled from the reference photo of a real R2-1 blank: white
    /// face, near-black (#202020) border/caption/numeral. US signs are
    /// black-on-white with no red ring — the red-ring circle is the
    /// Vienna/UK convention the HUD previously used.
    private static let signBlack = UIColor(red: 0.125, green: 0.125, blue: 0.125, alpha: 1)
    private static let signWhite = UIColor.white

    /// Overpass Bold (SIL OFL) — the open-source descendant of Highway
    /// Gothic, the typeface family on real US regulatory signs. The TTF is
    /// bundled (Package.swift `resources:` / project.yml resources phase)
    /// and registered once per process. Text layout below is calibrated
    /// empirically — a cap-height probe and a per-line tracking solve — so
    /// even if registration ever failed and the system heavy weight were
    /// used, the sign would still land on the measured R2-1 proportions.
    private static let signFontName = "Overpass-Bold"
    private static let registerSignFont: Void = {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle.main]
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: signFontName, withExtension: "ttf") {
                // .process scope: visible app-wide for this launch. A failure
                // is non-fatal — signFont falls back to the system heavy weight.
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    private static func signFont(_ size: CGFloat) -> UIFont {
        _ = registerSignFont
        return UIFont(name: signFontName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .heavy)
    }

    /// Draws the US-style speed-limit sign at any size. Both the phone HUD
    /// (`LimitSignView`) and the CarPlay limit button render through this
    /// single function so the two surfaces can never drift apart.
    ///
    /// This is a faithful Swift port of the user-approved HTML replica
    /// (`speed-limit-sign.html` in the repo root). Every layout number is a
    /// fraction of the sheet width, pixel-measured from the reference photo
    /// of a real R2-1 blank (1000×1250 units):
    ///
    ///     white margin 10 · border 28 thick · corner radius 30
    ///     SPEED  cap 171 · ink width 800 · baseline y 283
    ///     LIMIT  cap 171 · ink width 611 · baseline y 536  (gap 82)
    ///     50     cap 436 · ink width 750 · baseline y 1056 (gap 84)
    ///
    /// Text placement is ink-exact, exactly like the replica's canvas
    /// `actualBoundingBox` math: each font size is solved from a cap-height
    /// probe, each line's letter-spacing is solved so the INK width lands
    /// on the measured target, and lines are placed start-anchored so their
    /// ink is centered regardless of side bearings. The portrait sheet is
    /// letterboxed inside the square canvas (both call sites frame the
    /// image square), leaving transparent side margins.
    static func speedLimitSign(value: Int?, unit: String?, size: CGFloat) -> UIImage {
        let size = max(24, size)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { _ in

            // ---- Sheet blank ------------------------------------------------
            let canvasInset = size * 0.01            // keep AA edges off the canvas
            let sheetH = size - canvasInset * 2
            let sheetW = sheetH * (1000.0 / 1250.0)  // the 24"×30" regulatory blank
            let sheet = CGRect(x: (size - sheetW) / 2, y: canvasInset, width: sheetW, height: sheetH)
            let u = sheetW / 1000                    // one spec unit in points

            signWhite.setFill()
            UIBezierPath(roundedRect: sheet, cornerRadius: 30 * u).fill()
            let borderW = 28 * u
            let borderInset = 10 * u + borderW / 2   // white margin outside a stroke centered on its inset rect
            signBlack.setStroke()
            let border = UIBezierPath(
                roundedRect: sheet.insetBy(dx: borderInset, dy: borderInset),
                cornerRadius: max(2 * u, 30 * u - borderInset))
            border.lineWidth = borderW
            border.stroke()
            let faceCenterX = sheet.midX

            // ---- Ink-exact text engine --------------------------------------
            /// Ink extents of `text` under `font` + `kern`, measured from
            /// per-glyph bounding boxes and post-kern advances — CoreText's
            /// equivalent of the replica's canvas actualBoundingBox. Offsets
            /// are relative to the pen; `top` is the ink's height above the
            /// baseline.
            func measureLine(_ text: String, font: UIFont, kern: CGFloat)
                -> (line: CTLine, left: CGFloat, right: CGFloat, top: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                var left = CGFloat.greatestFiniteMagnitude
                var right = -CGFloat.greatestFiniteMagnitude
                var top = -CGFloat.greatestFiniteMagnitude
                var pen: CGFloat = 0
                for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                    let count = CTRunGetGlyphCount(run)
                    guard count > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                    var advances = [CGSize](repeating: .zero, count: count)
                    CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
                    var bounds = [CGRect](repeating: .zero, count: count)
                    // The font passed in IS the one attached to the string,
                    // so measuring with it reflects the actual weight.
                    CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, count)
                    for i in 0..<count {
                        left = min(left, pen + bounds[i].minX)
                        right = max(right, pen + bounds[i].maxX)
                        top = max(top, bounds[i].maxY)
                        pen += advances[i].width
                    }
                }
                if left > right { left = 0; right = 0 }
                if top < 0 { top = font.capHeight }
                return (line, left, right, top)
            }

            /// Cap-height ratio of the loaded font: ink top of 'H' per point.
            /// Solved at runtime (the replica's probe), so any font swap
            /// keeps the measured cap sizes exact.
            let capRatio: CGFloat = {
                let probe = signFont(100)
                return measureLine("H", font: probe, kern: 0).top / 100
            }()

            /// Fits a line to its measured spec: font size from the cap
            /// target, then per-gap letter-spacing so the INK width lands
            /// exactly on the ink target (the replica's tracking solve).
            /// If the font is naturally wider than the reference font at
            /// that cap size (Overpass vs. Highway Gothic edge cases), the
            /// size shrinks proportionally instead of squeezing glyphs —
            /// the ink width always wins; cap height yields as little as
            /// needed. Tracking is never negative (no glyph collisions).
            func fit(_ text: String, cap capTarget: CGFloat, ink inkTarget: CGFloat)
                -> (font: UIFont, kern: CGFloat) {
                guard text.count > 1 else { return (signFont(capTarget / capRatio), 0) }
                var font = signFont(capTarget / capRatio)
                var natural = measureLine(text, font: font, kern: 0)
                var width = natural.right - natural.left
                if width > inkTarget {
                    font = signFont(capTarget / capRatio * inkTarget / width)
                    natural = measureLine(text, font: font, kern: 0)
                    width = natural.right - natural.left
                }
                let kern = width < inkTarget
                    ? (inkTarget - width) / CGFloat(text.count - 1)
                    : 0
                return (font, kern)
            }

            /// Draws a measured line with its ink centered on the face and
            /// its BASELINE at `baselineFromTop` (top-down sheet
            /// coordinates) — start-anchored placement, as in the replica.
            func drawLine(_ measured: (line: CTLine, left: CGFloat, right: CGFloat, top: CGFloat),
                          baselineFromTop: CGFloat) {
                let ctx = UIGraphicsGetCurrentContext()
                ctx?.saveGState()
                ctx?.textMatrix = .identity
                ctx?.translateBy(x: 0, y: size)
                ctx?.scaleBy(x: 1, y: -1)
                ctx?.textPosition = CGPoint(x: faceCenterX - (measured.left + measured.right) / 2,
                                            y: size - baselineFromTop)
                CTLineDraw(measured.line, ctx!)
                ctx?.restoreGState()
            }

            // ---- Legend ------------------------------------------------------
            let placeholder = value == nil || value! <= 0
            // Real US signs carry no unit ("35", never "35 MPH"). Metric
            // signs (km/h) do, and metric users here historically needed the
            // disambiguation — the unit gets its own line below the numeral,
            // with the numeral compressed so the stack stays centered.
            let showUnit = !placeholder
                && unit?.isEmpty == false
                && unit?.uppercased() != "MPH"

            if placeholder {
                // The no-data state ("--"): two rounded bars centered in
                // the numeral band [620, 1056], sized down from the first
                // draft so they read as dashes rather than dots at HUD
                // scale (approved in the replica).
                let barW = 120 * u, barH = 105 * u, off = 140 * u
                let bandMid = sheet.minY + (620 + 436.0 / 2) * u
                signBlack.setFill()
                for dx in [-off, off] {
                    let rect = CGRect(x: faceCenterX + dx - barW / 2,
                                      y: bandMid - barH / 2,
                                      width: barW, height: barH)
                    UIBezierPath(roundedRect: rect, cornerRadius: 14 * u).fill()
                }
            } else {
                // Captions: cap size from the measurement, tracking solved
                // so the ink width lands exactly on the measured target.
                let (speedFont, speedKern) = fit("SPEED", cap: 171 * u, ink: 800 * u)
                drawLine(measureLine("SPEED", font: speedFont, kern: speedKern),
                         baselineFromTop: sheet.minY + 283 * u)
                let (limitFont, limitKern) = fit("LIMIT", cap: 171 * u, ink: 611 * u)
                drawLine(measureLine("LIMIT", font: limitFont, kern: limitKern),
                         baselineFromTop: sheet.minY + 536 * u)

                // Numeral: cap 436 on the unit-less layout; compressed to
                // 340 with the baseline pulled up to 958 when a unit line
                // shares the face (unit baseline 1138 keeps the stack
                // symmetric, mirroring the measured 112-unit top margin).
                // Numeral: cap 436 on the unit-less layout; compressed to
                // 340 with the baseline pulled up to 958 when a unit line
                // shares the face (unit baseline 1138 keeps the stack
                // symmetric, mirroring the measured 112-unit top margin).
                // fit() also keeps 3-digit limits (e.g. 120 km/h) inside
                // the face — oversized numerals shrink proportionally.
                let numeralText = "\(value!)"
                let numeralCap = (showUnit ? 340.0 : 436.0) * u
                let numeralBaseline = sheet.minY + (showUnit ? 958.0 : 1056.0) * u
                let numeralTargetW = (showUnit ? 585.0 : 750.0) * u
                let (numeralFont, numeralKern) = fit(numeralText, cap: numeralCap, ink: numeralTargetW)
                drawLine(measureLine(numeralText, font: numeralFont, kern: numeralKern),
                         baselineFromTop: numeralBaseline)

                if showUnit, let unit {
                    // The unit line is sized by INK WIDTH (≈32% of the sheet)
                    // rather than cap height: unit strings vary ("KM/H"), and
                    // width is what keeps the line subordinate + centered
                    // under the numeral for any string.
                    let unitText = unit.uppercased()
                    let probe = measureLine(unitText, font: signFont(100), kern: 0)
                    let probeWidth = max(1, probe.right - probe.left)
                    let unitFont = signFont(100 * (320 * u) / probeWidth)
                    drawLine(measureLine(unitText, font: unitFont, kern: 0),
                             baselineFromTop: sheet.minY + 1138 * u)
                }
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
