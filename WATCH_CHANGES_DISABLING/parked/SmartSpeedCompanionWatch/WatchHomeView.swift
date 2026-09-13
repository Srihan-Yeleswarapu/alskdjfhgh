// Path: SmartSpeedCompanionWatch/WatchHomeView.swift
//
// The wrist HUD. Mirrors the phone's Drive HUD hierarchy: status color,
// speed number, limit, and session controls — with a "Phone" chip when
// the paired phone is broadcasting a live reading.

import SwiftUI
import WatchKit

struct WatchHomeView: View {
    @ObservedObject var viewModel: WatchDriveViewModel
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                speedRing
                limitChip
                if viewModel.phoneChipText != nil || viewModel.isPhoneSessionActive {
                    phoneChip
                }
                if let summary = viewModel.lastSessionSummary {
                    summaryCard(summary)
                }
                sessionButtons
                settingsButton
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Speedio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                WatchSettingsView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Speed ring

    /// Ring gauge colored by status (DesignSystem tokens shared with the
    /// phone + Live Activity + widget), with the speed number centered.
    private var speedRing: some View {
        let tint = DesignSystem.colorForStatus(viewModel.status)
        let fraction = min(max(viewModel.speed / 120.0, 0), 1) // 0-120 display-unit span

        return ZStack {
            // Track (full circle) + progress arc.
            Circle()
                .stroke(DesignSystem.bgPanel, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(Int(viewModel.speed.rounded()))")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(tint)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(viewModel.unitLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .frame(width: 110, height: 110)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(viewModel.speed.rounded())) \(viewModel.unitLabel)")
    }

    // MARK: - Limit

    private var limitChip: some View {
        let limitText = viewModel.limitMph == 0
            ? "LIMIT \u{2014}"
            : "LIMIT \(viewModel.displayLimit) \(viewModel.unitLabel)"

        return Text(limitText)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(DesignSystem.bgPanel))
            .accessibilityLabel(limitText)
    }

    // MARK: - Phone chip

    /// Live phone reading over WCSession. Gray while the phone drives
    /// normally; amber when the phone reports over-limit so a driver
    /// comparing devices notices immediately.
    private var phoneChip: some View {
        let over = viewModel.phoneState?.status == "over"
        return HStack(spacing: 4) {
            Circle()
                .fill(over ? DesignSystem.amber : DesignSystem.cyan)
                .frame(width: 6, height: 6)
            Text("Phone \(viewModel.phoneChipText ?? "—")")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(DesignSystem.bgPanel))
        .accessibilityLabel("Phone reports \(viewModel.phoneChipText ?? "no data")")
    }

    // MARK: - Summary

    private func summaryCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignSystem.bgPanel.opacity(0.8))
            )
    }

    // MARK: - Session controls

    private var sessionButtons: some View {
        VStack(spacing: 6) {
            if viewModel.isWatchSessionActive {
                Button {
                    viewModel.endWatchSession()
                } label: {
                    Label("End Watch Drive", systemImage: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .tint(DesignSystem.alertRed)
            } else {
                Button {
                    viewModel.startWatchSession()
                } label: {
                    Label("Start Watch Drive", systemImage: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .tint(DesignSystem.neonGreen)
            }

            Button {
                viewModel.togglePhoneSession()
            } label: {
                Label(
                    viewModel.isPhoneSessionActive ? "End Phone Drive" : "Start Phone Drive",
                    systemImage: "iphone.gen2"
                )
                .font(.system(size: 13, weight: .semibold))
            }
            .tint(viewModel.isPhoneSessionActive ? DesignSystem.alertRed : DesignSystem.cyan)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(.system(size: 13, weight: .semibold))
        }
        .tint(.white.opacity(0.6))
    }
}
