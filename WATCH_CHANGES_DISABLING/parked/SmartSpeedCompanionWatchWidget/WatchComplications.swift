// Path: SmartSpeedCompanionWatchWidget/WatchComplications.swift
//
// Speedio watch complications (WidgetKit accessory widgets, watchOS 11+).
//
// DATA SOURCE: the watch-local App Group
// `group.com.smartspeedcompanion.app.watch`, written by
// `WatchDriveViewModel.writeComplicationSnapshot()` on session start/end.
//
// REFRESH BUDGET: watch complication timelines are budgeted far more
// tightly than iOS widgets. We therefore render STATE (recording? last
// speed?) rather than live speed — a 1 Hz complication refresh would burn
// the entire daily budget in minutes. The live readout lives in the app
// and the Smart Stack Live Activity mirror (Phase 0).

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let lastSpeed: Int
    let statusId: String
}

struct WatchComplicationProvider: TimelineProvider {
    private var suite: UserDefaults? {
        UserDefaults(suiteName: "group.com.smartspeedcompanion.app.watch")
    }

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: Date(), isRecording: false, lastSpeed: 42, statusId: "safe")
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        // Single entry; the watch app reloads timelines explicitly on
        // session start/end, which is the only time this data changes.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> WatchComplicationEntry {
        let defaults = suite
        return WatchComplicationEntry(
            date: Date(),
            isRecording: defaults?.bool(forKey: "watchComplicationRecording") ?? false,
            lastSpeed: defaults?.integer(forKey: "watchComplicationLastSpeed") ?? 0,
            statusId: defaults?.string(forKey: "watchComplicationLastStatus") ?? "safe"
        )
    }
}

// MARK: - Rendering

private func statusTint(_ statusId: String) -> Color {
    switch statusId {
    case "over": return DesignSystem.alertRed
    case "warning": return DesignSystem.amber
    default: return DesignSystem.neonGreen
    }
}

struct WatchComplicationEntryView: View {
    var entry: WatchComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        default:
            rectangular
        }
    }

    /// Circular: gauge ring filled by the last speed (0-120 span, same as
    /// the in-app watch ring), with either "REC" or the speed inside.
    private var circular: some View {
        let tint = entry.isRecording ? DesignSystem.alertRed : statusTint(entry.statusId)
        let fraction = min(max(Double(entry.lastSpeed) / 120.0, 0), 1)
        let label = entry.isRecording ? "REC" : "\(entry.lastSpeed)"

        return ZStack {
            Circle()
                .stroke(.white.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 15, weight: .black, design: .rounded))
                .minimumScaleFactor(0.6)
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityLabel(
            entry.isRecording ? "Drive recording in progress" : "Last recorded speed \(entry.lastSpeed)"
        )
    }

    /// Rectangular: app-brand row + last speed / recording state.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Circle()
                    .fill(entry.isRecording ? DesignSystem.alertRed : DesignSystem.cyan)
                    .frame(width: 6, height: 6)
                Text("SPEEDIO")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            if entry.isRecording {
                Text("Recording")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(DesignSystem.alertRed)
            } else {
                Text("\(entry.lastSpeed)")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundColor(statusTint(entry.statusId))
                Text("last speed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .combine)
    }

    /// Inline: single line for text-only slots.
    private var inline: some View {
        Text(entry.isRecording ? "Speedio REC" : "Speedio \(entry.lastSpeed)")
            .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Bundle

@main
struct SpeedioWatchComplications: WidgetBundle {
    var body: some Widget {
        SpeedioWatchComplication()
    }
}

struct SpeedioWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SpeedioWatchComplication", provider: WatchComplicationProvider()) { entry in
            WatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Speedio")
        .description("Session state and last recorded speed.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}
