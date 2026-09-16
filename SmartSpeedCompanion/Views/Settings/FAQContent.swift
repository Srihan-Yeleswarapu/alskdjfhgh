// FAQContent.swift
//
// The "Common Questions" content behind Settings → SUPPORT → Common
// Questions. Kept as pure data so adding a question is a one-line append —
// the view (FAQView) renders whatever lives here.
//
// Copy rules for this file (enforced by FAQContentTests):
//   • The first sentence must DIRECTLY answer the question.
//   • No answer may imply offline capability — Speedio is an online
//     product; lookups, search, and limit data require connectivity.
//   • No placeholder text.

import Foundation

/// One question-and-answer entry.
struct FAQItem: Identifiable {
    let id: String
    let question: String
    let answer: String
}

/// A grouped section of the FAQ list.
struct FAQCategory: Identifiable {
    let id: String
    let title: String
    let items: [FAQItem]
}

enum FAQContent {

    /// The five questions from direct user feedback. Tests pin these
    /// verbatim — do not reword without updating the tests.
    static let requiredQuestions: [String] = [
        "Why doesn't my car's speedometer match the app's speed?",
        "Why does the speed limit show \"--\"?",
        "How do I end a session in Apple CarPlay?",
        "How do I add a stop in Apple CarPlay?",
        "Why does my music stop when the app beeps or navigates?"
    ]

    static let categories: [FAQCategory] = [

        // MARK: - Speed & Limits

        FAQCategory(id: "speed-limits", title: "SPEED & LIMITS", items: [

            FAQItem(
                id: "speedo-mismatch",
                question: "Why doesn't my car's speedometer match the app's speed?",
                answer: "Your car's speedometer is deliberately not accurate. Regulations require it to never show less than your true speed, so most cars display 5–10% MORE than you are actually traveling, and tire size or pressure can skew it further. Speedio calculates your true speed from GPS — so when the two disagree, the car is the one reading high. The gap grows the faster you go."
            ),

            FAQItem(
                id: "limit-dashes",
                question: "Why does the speed limit show \"--\"?",
                answer: "The app hasn't been able to look up the limit for your road yet — almost always a weak GPS fix or no internet connection for the live lookup. To fix it: check you have cell or Wi-Fi service, drive a short distance so the app gets a better GPS position, or tap the speed-limit sign to force an immediate retry."
            ),

            FAQItem(
                id: "speed-zero-creep",
                question: "Why does my speed show 0 when I'm creeping forward?",
                answer: "At walking speeds GPS is noisy, so the app clamps sub-few-mph jitter to a steady 0 instead of flickering 0 → 3 → 0 in stop-and-go traffic. You are genuinely moving that slowly — the display just refuses to bounce around."
            ),

            FAQItem(
                id: "buffer-meaning",
                question: "What does BUFFER mean?",
                answer: "BUFFER is extra speed you're allowed above the limit before any alert fires: with a 5 mph buffer on a 65 road, warnings start at 70. Set it in Settings → ALERTS so gentle downhill coasting doesn't trigger the alarm."
            ),

            FAQItem(
                id: "status-colors",
                question: "What do SAFE, WARNING, and OVER mean?",
                answer: "They're your live speed status. SAFE (green) means at or under the limit plus your buffer. WARNING (amber) means you're approaching it. OVER (red) means you're above it — that's where alerts fire."
            ),

            FAQItem(
                id: "limit-sources",
                question: "Where do the speed limits come from?",
                answer: "From professional map providers — HERE first, with OpenStreetMap and ArcGIS as backups — looked up live for the exact road you're on and cached on your phone. The tiny label under the speed-limit sign shows which source answered."
            ),

            FAQItem(
                id: "battery-data",
                question: "How much battery and data does Speedio use?",
                answer: "Very little data: limit lookups only run every ~80 m in town and ~250 m on the highway, and results are cached in a local grid, so typical drives use a few kilobytes. Battery use is dominated by GPS itself, the same as any navigation app."
            )
        ]),

        // MARK: - Apple CarPlay

        FAQCategory(id: "carplay", title: "APPLE CARPLAY", items: [

            FAQItem(
                id: "carplay-end-session",
                question: "How do I end a session in Apple CarPlay?",
                answer: "Tap the session timer in CarPlay's top bar — the red dot with your drive time — then tap the red End Session button in the panel that appears. You can also say \"End my drive in Speedio\" to Siri."
            ),

            FAQItem(
                id: "carplay-add-stop",
                question: "How do I add a stop in Apple CarPlay?",
                answer: "Tap the + button on the CarPlay map, pick a category (gas, coffee, food) or type what you're looking for, then tap a result to confirm. If you're navigating, Speedio re-plans the route through the stop; if not, it starts a new trip to that stop."
            ),

            FAQItem(
                id: "carplay-pan-map",
                question: "How do I move the map on CarPlay?",
                answer: "Tap the map to open the pan controls — drag, use the arrows, or pinch to zoom. Tap Done to snap the map back to your car."
            )
        ]),

        // MARK: - Siri & Voice

        FAQCategory(id: "siri-voice", title: "SIRI & VOICE", items: [

            FAQItem(
                id: "siri-commands",
                question: "What can I say to Siri?",
                answer: "\"Set destination to ⟨place⟩ in Speedio\" (also \"through / from / using / with Speedio\"), \"Stop navigation\", \"Start my drive\", \"End my drive\", \"What's my speed limit\", \"When will I arrive\", and \"How was my last drive\". On the CarPlay map, the mic button listens for any destination."
            ),

            FAQItem(
                id: "music-ducking",
                question: "Why does my music stop when the app beeps or navigates?",
                answer: "Speedio briefly takes over the audio so the alert tone and voice directions are actually audible over your music — without that, you'd never hear them. Your music resumes on its own the moment the alert or voice cue finishes. If you want quiet without losing your music, tap \"I Know\" on the overspeed alert."
            )
        ]),

        // MARK: - App Basics

        FAQCategory(id: "basics", title: "APP BASICS", items: [

            FAQItem(
                id: "driving-score",
                question: "What is my driving score?",
                answer: "A per-session rating built from how long you stayed within the limit and how far over you went. It appears when you end a session — or ask Siri \"How was my last drive in Speedio\" anytime."
            ),

            FAQItem(
                id: "units-switch",
                question: "How do I switch between MPH and KM/H?",
                answer: "Settings → UNITS → Metric or Imperial. Speed, limits, buffers, and distances convert everywhere instantly, including the Home Screen widget."
            ),

            FAQItem(
                id: "privacy",
                question: "Is my location or voice data private?",
                answer: "Nothing leaves your phone. There's no account, no analytics, no uploads; the microphone is used only for \"Ask to Siri\", and its speech recognition runs entirely on-device."
            )
        ])
    ]

    /// All items flattened, for tests and quick lookups.
    static var allItems: [FAQItem] {
        categories.flatMap(\.items)
    }
}
