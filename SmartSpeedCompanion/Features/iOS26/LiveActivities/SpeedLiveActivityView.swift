// Path: Features/iOS26/LiveActivities/SpeedLiveActivityView.swift
//
// Refactored to delegate from `body` into private helper closures so
// the Swift type-checker evaluates each region in bounded time rather
// than blowing up on the combined view-graph (CI was OOM-killed during
// `SwiftDriver SmartSpeedCompanionWidget normal arm64`). Behavior is
// unchanged from the previous inlined version.
//
// [WATCH-DISABLED] The Apple Watch Smart Stack mirroring (Phase 0) is
// commented out below while iOS fixes land: the
// `.supplementalActivityFamilies([.small])` opt-in, the
// `@Environment(\.activityFamily)` switch, and the wrist-sized `watchCard`
// layout (+ its helpers). The paired `supplementalActivityFamilies` static
// on `SpeedActivityAttributes` is commented out too. The Lock-Screen
// rendering itself is unchanged iOS behavior. The full original watch
// implementation is preserved in WATCH_CHANGES_DISABLING/ (see
// README-RESTORING.md).
// Shared render helpers (status colors, distance/time formatting, maneuver
// labeling) remain hoisted to fileprivate free functions shared by the
// Widget struct (Dynamic Island) and the content struct (Lock Screen).
import SwiftUI
import WidgetKit
import ActivityKit
import CoreLocation
import Foundation

@available(iOS 16.1, *)
struct SpeedLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedActivityAttributes.self) { context in
            SpeedLiveActivityContentView(context: context)
        } dynamicIsland: { context in
            dynamicIsland(context: context)
        }
        // [WATCH-DISABLED] Smart Stack opt-in removed for now (it was inert
        // on iOS but mirrored the activity onto the Watch):
        // .supplementalActivityFamilies([.small])
    }

    // MARK: - Dynamic Island
    private func dynamicIsland(context: ActivityViewContext<SpeedActivityAttributes>) -> DynamicIsland {
        let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
        let limitDisplay = SpeedFormatting.displayLimit(
            forMph: context.state.speedLimit,
            measurementSystem: measurementSystem
        )

        return DynamicIsland {
            // Inlined (not via a private helper) so the
            // `DynamicIslandExpandedContentBuilder` can see the actual
            // `ConditionalContent<...>` type from the `if let` branch.
            // When wrapped in an opaque `some View` helper, the
            // `Expanded` generic parameter of `DynamicIslandExpandedRegion`
            // could not be inferred.
            DynamicIslandExpandedRegion(.center) {
                if let maneuver = context.state.nextManeuver {
                    expandedWithManeuver(context: context, maneuver: maneuver)
                } else {
                    expandedWithoutManeuver(context: context, unitShort: unitShort, limitDisplay: limitDisplay)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                expandedBottom(status: context.state.status)
            }
        } compactLeading: {
            compactLeading(context: context)
        } compactTrailing: {
            compactTrailing(context: context)
        } minimal: {
            minimal(context: context)
        }
    }

    // `expandedCenter` was inlined into the `DynamicIslandExpandedRegion(.center)`
    // closure above to satisfy `DynamicIslandExpandedContentBuilder`'s generic
    // `Expanded` parameter inference — see the inline note at the call site.

    @ViewBuilder
    private func expandedWithManeuver(
        context: ActivityViewContext<SpeedActivityAttributes>,
        maneuver: String
    ) -> some View {
        HStack(spacing: 20) {
            if let img = context.state.nextManeuverImageName {
                Image(systemName: img)
                    .font(.title)
                    .foregroundColor(DesignSystem.cyan)
            }
            VStack(alignment: .leading) {
                Text(dynamicIslandManeuverLabel(maneuver))
                    .font(.headline)
                    .accessibilityLabel(maneuver)
                Text(formatNavigationDistance(context.state.distanceToNextTurn ?? 0))
                    .font(.subheadline.bold())
                    .foregroundColor(DesignSystem.cyan)
            }
            Spacer()
            if let eta = context.state.eta {
                VStack(alignment: .trailing) {
                    Text("ETA")
                        .font(.caption)
                    Text(eta, format: .dateTime.hour().minute())
                        .font(.headline)
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func expandedWithoutManeuver(
        context: ActivityViewContext<SpeedActivityAttributes>,
        unitShort: String,
        // See `leftColumn` for why this is `Int` (mirrors the actual
        // return type of `SpeedFormatting.displayLimit`).
        limitDisplay: Int
    ) -> some View {
        VStack {
            Text("\(Int(context.state.speed))")
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundColor(speedStatusColor(context.state.status))

            HStack(spacing: 20) {
                Text("LIMIT: \(limitDisplay) \(unitShort)")
                if context.state.isRecording {
                    Text(formatElapsedTime(context.state.sessionDuration))
                        .monospacedDigit()
                }
            }
            .font(.caption.bold())
            .foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private func expandedBottom(status: String) -> some View {
        let tint = speedStatusColor(status)
        ZStack {
            Capsule()
                .fill(tint.opacity(0.2))
                .frame(height: 30)
            Text(status.uppercased())
                .font(.caption.bold())
                .foregroundColor(tint)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func compactLeading(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if let img = context.state.nextManeuverImageName {
            Image(systemName: img)
                .foregroundColor(DesignSystem.cyan)
        } else {
            Text("\(Int(context.state.speed))")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundColor(speedStatusColor(context.state.status))
        }
    }

    @ViewBuilder
    private func compactTrailing(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if context.state.nextManeuver != nil {
            Text(formatNavigationDistance(context.state.distanceToNextTurn ?? 0))
                .font(.caption.bold())
                .foregroundColor(DesignSystem.cyan)
        } else {
            Circle()
                .fill(speedStatusColor(context.state.status))
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private func minimal(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        if let img = context.state.nextManeuverImageName {
            Image(systemName: img)
                .foregroundColor(DesignSystem.cyan)
        } else {
            Text("\(Int(context.state.speed))")
                .font(.system(.caption, design: .rounded).bold())
                .foregroundColor(speedStatusColor(context.state.status))
        }
    }
}

// MARK: - Lock Screen content
//
// Originally one content struct for both presentation families:
// `activityFamily` was `.medium` on the iOS Lock Screen / StandBy and
// `.small` when watchOS 11 rendered the mirrored activity in the Watch
// Smart Stack. [WATCH-DISABLED] the Smart Stack branch is commented out
// below; the Lock Screen card is the sole presentation.
@available(iOS 16.1, *)
private struct SpeedLiveActivityContentView: View {
    let context: ActivityViewContext<SpeedActivityAttributes>

    // [WATCH-DISABLED] Watch-family presentation state + switch
    // (WWDC24-10068) — commented out while iOS fixes land:
    // @Environment(\.activityFamily) private var activityFamily
    // // Always-On display state on Apple Watch — the Smart Stack card keeps
    // // rendering with the wrist down, so the dimmed variant must be cheap
    // // and low-contrast rather than a static snapshot.
    // @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    //
    // var body: some View {
    //     switch activityFamily {
    //     case .small:
    //         // Smart Stack cards render light-mode by default; pin the
    //         // scheme so the dark-palette status colors keep their
    //         // designed contrast in both lamp states.
    //         watchCard
    //             .preferredColorScheme(.light)
    //     default:
    //         lockScreenCard
    //     }
    // }

    var body: some View {
        lockScreenCard
    }

    // MARK: - Lock-screen / StandBy card (medium family — moved verbatim)

    @ViewBuilder
    private var lockScreenCard: some View {
        let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
        let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
        let limitDisplay = SpeedFormatting.displayLimit(
            forMph: context.state.speedLimit,
            measurementSystem: measurementSystem
        )

        VStack(spacing: 0) {
            Rectangle()
                .fill(speedStatusColor(context.state.status))
                .frame(height: 3)

            HStack(alignment: .center, spacing: 16) {
                leftColumn(context: context, unitShort: unitShort, limitDisplay: limitDisplay)
                Spacer(minLength: 8)
                rightColumn(context: context)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(DesignSystem.bgCard.opacity(0.92))
        .widgetBackground(DesignSystem.bgCard.opacity(0.8))
    }

    @ViewBuilder
    private func leftColumn(
        context: ActivityViewContext<SpeedActivityAttributes>,
        unitShort: String,
        // `SpeedFormatting.displayLimit` returns `Int`; the LIMIT caption
        // below uses it inside `\(limitDisplay)` so the Int is fine.
        limitDisplay: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            statusPill(status: context.state.status)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(context.state.speed))")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundColor(speedStatusColor(context.state.status))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unitShort)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }

            let limitText = context.state.speedLimit == 0
                ? "LIMIT \u{2014}"
                : "LIMIT \(limitDisplay) \(unitShort)"
            Text(limitText)
                .font(.caption2.weight(.bold))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

    // NOTE: deliberately NOT @ViewBuilder — the body mixes a `switch`
    // statement with multiple `let` declarations and a single returned
    // `Text`. @ViewBuilder would force `let label: String` to flow
    // through `buildExpression` (which requires `View`), producing
    // `'buildExpression' is unavailable: this expression does not
    // conform to 'View'`. Plain `func ... -> some View` with an
    // explicit `return` lets us treat the lets as ordinary locals.
    private func statusPill(status: String) -> some View {
        let label: String
        switch status {
        case "over":    label = "OVER LIMIT"
        case "warning": label = "WARNING"
        default:        label = "SAFE"
        }
        let tint = speedStatusColor(status)
        return Text(label)
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.85)))
            .overlay(Capsule().stroke(tint, lineWidth: 0.5))
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func rightColumn(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if context.state.isRecording {
                recordingBadge(context: context)
            } else if let maneuver = context.state.nextManeuver {
                maneuverSummary(context: context, maneuver: maneuver)
            }
        }
    }

    @ViewBuilder
    private func recordingBadge(context: ActivityViewContext<SpeedActivityAttributes>) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DesignSystem.alertRed)
                .frame(width: 6, height: 6)
            Text("REC")
                .font(.caption.weight(.black))
                .foregroundColor(DesignSystem.alertRed)
        }
        Text(formatElapsedTime(context.state.sessionDuration))
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundColor(.white)
    }

    @ViewBuilder
    private func maneuverSummary(
        context: ActivityViewContext<SpeedActivityAttributes>,
        maneuver: String
    ) -> some View {
        HStack(spacing: 4) {
            if let img = context.state.nextManeuverImageName {
                Image(systemName: img)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DesignSystem.cyan)
            }
            Text(dynamicIslandManeuverLabel(maneuver))
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .accessibilityLabel(maneuver)
        }
        Text(formatNavigationDistance(context.state.distanceToNextTurn ?? 0))
            .font(.caption2.weight(.bold))
            .foregroundColor(DesignSystem.cyan)
    }

    // [WATCH-DISABLED] Apple Watch Smart Stack card (small family). The
    // whole wrist layout below is commented out while iOS fixes land; the
    // Lock Screen card is unaffected.
    //
    // /// Wrist-sized layout: the speed number is the hero, the limit and a
    // /// one-line secondary readout (REC timer or next maneuver) sit beneath.
    // /// A leading status rail carries the safe/warning/over color so the
    // /// state reads at a 2-second wrist glance without any text parsing.
    // ///
    // /// Update cadence is inherited from the phone: `DriveViewModel` coalesces
    // /// Live Activity updates (~5 s tick), which the system synchronizes to
    // /// the Watch with its own battery budget (WWDC24-10068) — no extra
    // /// watch-side update work is added by this view.
    // private var watchCard: some View {
    //     let measurementSystem = SpeedFormatting.measurementSystemFromAppGroup()
    //     let unitShort = SpeedFormatting.unitLabelShort(measurementSystem: measurementSystem)
    //     let limitDisplay = SpeedFormatting.displayLimit(
    //         forMph: context.state.speedLimit,
    //         measurementSystem: measurementSystem
    //     )
    //     let tint = speedStatusColor(context.state.status)
    //
    //     return ZStack(alignment: .leading) {
    //         RoundedRectangle(cornerRadius: 14, style: .continuous)
    //             .fill(DesignSystem.bgCard.opacity(isLuminanceReduced ? 0.35 : 0.92))
    //
    //         // Status rail — dropped to a flat strip while dimmed (AOD keeps
    //         // fill-free, thin shapes to avoid burn-in / redraw churn).
    //         Capsule()
    //             .fill(tint.opacity(isLuminanceReduced ? 0.55 : 1.0))
    //             .frame(width: 5)
    //             .padding(.vertical, 10)
    //
    //         VStack(alignment: .leading, spacing: 2) {
    //             HStack(alignment: .firstTextBaseline, spacing: 3) {
    //                 Text("\(Int(context.state.speed))")
    //                     .font(.system(size: 44, weight: .black, design: .rounded))
    //                     .monospacedDigit()
    //                     .foregroundColor(tint)
    //                     .lineLimit(1)
    //                     .minimumScaleFactor(0.6)
    //                 Text(unitShort)
    //                     .font(.system(size: 12, weight: .black))
    //                     .foregroundColor(.white.opacity(isLuminanceReduced ? 0.4 : 0.55))
    //             }
    //
    //             let limitText = context.state.speedLimit == 0
    //                 ? "LIMIT \u{2014}"
    //                 : "LIMIT \(limitDisplay) \(unitShort)"
    //             Text(limitText)
    //                 .font(.system(size: 12, weight: .bold, design: .rounded))
    //                 .foregroundColor(.white.opacity(isLuminanceReduced ? 0.45 : 0.7))
    //                 .lineLimit(1)
    //
    //             watchSecondaryLine
    //         }
    //         .padding(.leading, 14)
    //         .padding(.trailing, 10)
    //         .padding(.vertical, 8)
    //     }
    //     .frame(maxWidth: .infinity, maxHeight: .infinity)
    //     .widgetBackground(Color.clear)
    //     .accessibilityElement(children: .combine)
    //     .accessibilityLabel(watchAccessibilityLabel)
    // }

    // /// Second row under the limit: recording duration while a session is
    // /// active, otherwise the next maneuver + distance while navigating.
    // @ViewBuilder
    // private var watchSecondaryLine: some View {
    //     if context.state.isRecording {
    //         HStack(spacing: 4) {
    //             Circle()
    //                 .fill(DesignSystem.alertRed)
    //                 .frame(width: 5, height: 5)
    //                 .opacity(isLuminanceReduced ? 0.6 : 1.0)
    //             Text(formatElapsedTime(context.state.sessionDuration))
    //                 .font(.system(size: 12, weight: .bold, design: .monospaced))
    //                 .foregroundColor(.white.opacity(isLuminanceReduced ? 0.5 : 0.85))
    //         }
    //     } else if let maneuver = context.state.nextManeuver {
    //         HStack(spacing: 4) {
    //             if let img = context.state.nextManeuverImageName {
    //                 Image(systemName: img)
    //                     .font(.system(size: 11, weight: .bold))
    //                     .foregroundColor(DesignSystem.cyan)
    //             }
    //             Text("\(formatNavigationDistance(context.state.distanceToNextTurn ?? 0)) · \(dynamicIslandManeuverLabel(maneuver))")
    //                 .font(.system(size: 12, weight: .bold))
    //                 .foregroundColor(DesignSystem.cyan)
    //                 .lineLimit(1)
    //                 .minimumScaleFactor(0.7)
    //         }
    //     }
    // }

    // private var watchAccessibilityLabel: String {
    //     var parts: [String] = []
    //     switch context.state.status {
    //     case "over":    parts.append("Over the speed limit")
    //     case "warning": parts.append("Approaching the speed limit")
    //     default:        parts.append("Within the speed limit")
    //     }
    //     parts.append("\(Int(context.state.speed))")
    //     if context.state.speedLimit > 0 {
    //         let limitDisplay = SpeedFormatting.displayLimit(
    //             forMph: context.state.speedLimit,
    //             measurementSystem: SpeedFormatting.measurementSystemFromAppGroup()
    //         )
    //         parts.append("limit \(limitDisplay)")
    //     }
    //     if context.state.isRecording {
    //         parts.append("recording")
    //     } else if let maneuver = context.state.nextManeuver {
    //         parts.append("next, \(dynamicIslandManeuverLabel(maneuver))")
    //     }
    //     return parts.joined(separator: ", ")
    // }
}

// MARK: - Shared render helpers
//
// Hoisted from struct methods to fileprivate free functions so the Widget
// struct (Dynamic Island) and SpeedLiveActivityContentView (Lock Screen +
// Watch Smart Stack) share one implementation.

/// Status string ("safe" | "warning" | "over") → design-system color.
fileprivate func speedStatusColor(_ status: String) -> Color {
    switch status {
    case "over": return DesignSystem.alertRed
    case "warning": return DesignSystem.amber
    default: return DesignSystem.neonGreen
    }
}

/// The arrow already communicates the turn direction in the Dynamic
/// Island. Keep the street target in the text so the compact card does
/// not redundantly say "Turn right" and then truncate the road name.
fileprivate func dynamicIslandManeuverLabel(_ instruction: String) -> String {
    let words = instruction.split(whereSeparator: { $0.isWhitespace })
    guard let ontoIndex = words.firstIndex(where: {
        String($0)
            .lowercased()
            .trimmingCharacters(in: .punctuationCharacters) == "onto"
    }), ontoIndex + 1 < words.count else {
        return instruction
    }

    let street = words.dropFirst(ontoIndex + 1).joined(separator: " ")
    return street.isEmpty ? instruction : "Onto \(street)"
}

fileprivate func formatNavigationDistance(_ distance: CLLocationDistance) -> String {
    SpeedFormatting.navigationDistanceLabel(
        forMeters: distance,
        measurementSystem: SpeedFormatting.measurementSystemFromAppGroup()
    )
}

fileprivate func formatElapsedTime(_ interval: TimeInterval) -> String {
    let i = Int(interval)
    return String(format: "%02d:%02d", (i % 3600) / 60, i % 60)
}

extension View {
    // Helper to support StandBy seamlessly in iOS 17 while targeting 16
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { color }
        } else {
            self.background(color)
        }
    }
}
