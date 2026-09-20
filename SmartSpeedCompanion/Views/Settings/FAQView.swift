// FAQView.swift
//
// "Common Questions" — Settings → SUPPORT. A grouped, expandable list of
// the questions new users actually ask (content lives in FAQContent.swift).
// Presentation follows the app's established sheet pattern
// (OfflineRegionsListView): large detent, drag indicator, dark scheme.

import SwiftUI

struct FAQView: View {
    @Environment(\.dismiss) private var dismiss
    /// Tracks which question is expanded. Single-open keeps the list tidy
    /// and mirrors how iOS Settings-style disclosure lists behave.
    @State private var expandedItemID: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(FAQContent.categories) { category in
                    Section(
                        header: Text(category.title)
                            .font(DesignSystem.labelFont)
                            .foregroundColor(DesignSystem.cyan)
                    ) {
                        ForEach(category.items) { item in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedItemID == item.id },
                                    set: { isExpanded in
                                        // Tap-to-toggle; opening one closes the other.
                                        expandedItemID = isExpanded ? item.id : nil
                                    }
                                )
                            ) {
                                Text(item.answer)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.85))
                                    .padding(.vertical, 4)
                            } label: {
                                Text(item.question)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Escalation path for anything the FAQ doesn't cover.
                Section {
                    Button(action: {
                        if let url = URL(string: "mailto:speedsenseapp@gmail.com?subject=Speedio%20Question") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Label("Still stuck? Report an issue", systemImage: "envelope.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(DesignSystem.cyan)
                    }
                }
                .listRowBackground(DesignSystem.bgPanel)
            }
            .scrollContentBackground(.hidden)
            .background(DesignSystem.bgDeep.ignoresSafeArea())
            .navigationTitle("COMMON QUESTIONS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.cyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
