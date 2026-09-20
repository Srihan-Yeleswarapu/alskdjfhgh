import XCTest
@testable import SmartSpeedCompanion

/// Regression coverage for Settings → SUPPORT → Common Questions.
/// Pins the five questions that came from direct user feedback, guards
/// answer quality (non-empty, no placeholders), and enforces two product
/// copy rules: no answer may imply offline capability (Speedio is an online
/// product), and every item must live in a category.
final class FAQContentTests: XCTestCase {

    // MARK: - Required questions

    func testAllUserRequestedQuestionsArePresent() throws {
        let questions = FAQContent.allItems.map(\.question)
        for required in FAQContent.requiredQuestions {
            XCTAssertTrue(
                questions.contains(required),
                "Required FAQ question missing: \(required)"
            )
        }
        // Content list and the pinned list stay in sync.
        XCTAssertEqual(FAQContent.requiredQuestions.count, 5)
    }

    // MARK: - Answer quality

    func testEveryItemHasASubstantiveAnswerInACategory() {
        let items = FAQContent.allItems
        XCTAssertGreaterThanOrEqual(items.count, 15, "The FAQ should stay a rich resource.")
        for item in items {
            XCTAssertFalse(item.question.trimmingCharacters(in: .whitespaces).isEmpty, "Empty question: \(item.id)")
            XCTAssertGreaterThanOrEqual(
                item.answer.count, 60,
                "Answer for '\(item.id)' is too short to be a real answer."
            )
            let lowered = item.answer.lowercased()
            for marker in ["todo", "placeholder", "tbd", "lorem ipsum"] {
                XCTAssertFalse(lowered.contains(marker), "Answer for '\(item.id)' contains placeholder text.")
            }
        }
        // Every item must belong to exactly one declared category.
        let categorized = FAQContent.categories.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(categorized), Set(items.map(\.id)), "Every item must live in exactly one category.")
        XCTAssertEqual(categorized.count, items.count, "No duplicate items across categories.")
    }

    // MARK: - Product copy rules

    func testNoAnswerImpliesOfflineCapability() {
        // Speedio is an online product: lookups and search need connectivity.
        // These words would falsely promise (or explain) offline behavior.
        let forbidden = ["offline", "without internet", "no internet needed", "works offline", "airplane mode"]
        for item in FAQContent.allItems {
            let lowered = item.answer.lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    lowered.contains(word),
                    "Answer for '\(item.id)' mentions '\(word)' — Speedio must not imply offline capability."
                )
            }
        }
    }

    func testAnswersLeadWithDirectAnswers() {
        // Each required answer's first sentence must actually answer the
        // question rather than drift into related context. Checked against
        // the pinned opening fragments agreed in the plan.
        let answerFor: (String) -> String? = { question in
            FAQContent.allItems.first { $0.question == question }?.answer
        }
        let expectedOpenings: [String: String] = [
            "Why doesn't my car's speedometer match the app's speed?":
                "Your car's speedometer is deliberately not accurate.",
            "Why does the speed limit show \"--\"?":
                "The app hasn't been able to look up the limit",
            "How do I end a session in Apple CarPlay?":
                "Tap the session timer in CarPlay's top bar",
            "How do I add a stop in Apple CarPlay?":
                "Tap the + button on the CarPlay map",
            "Why does my music stop when the app beeps or navigates?":
                "Speedio briefly takes over the audio"
        ]
        for (question, opening) in expectedOpenings {
            let answer = answerFor(question)
            XCTAssertNotNil(answer, "Missing answer for required question: \(question)")
            XCTAssertTrue(
                answer?.hasPrefix(opening) == true,
                "Answer for '\(question)' must open by directly answering: '\(opening)'"
            )
        }
    }

    // MARK: - Settings wiring

    func testSettingsViewWiresCommonQuestionsEntry() throws {
        let source = try String(contentsOfFile: settingsSourcePath(), encoding: .utf8)
        XCTAssertTrue(
            source.contains("showingFAQ"),
            "Settings must own the FAQ sheet state."
        )
        XCTAssertTrue(
            source.contains("Common Questions"),
            "SUPPORT must expose the Common Questions row."
        )
        XCTAssertTrue(
            source.contains(".sheet(isPresented: $showingFAQ)"),
            "The FAQ must present as a sheet."
        )
        XCTAssertTrue(
            source.contains("FAQView()"),
            "The sheet must present FAQView."
        )
        // The row should sit in SUPPORT, before Report Issue.
        let supportBody = try sourceSection(in: source, anchor: "Section(header: Text(\"SUPPORT\")")
        let faqRange = supportBody.range(of: "Common Questions")
        let reportRange = supportBody.range(of: "Report Issue")
        XCTAssertNotNil(faqRange)
        XCTAssertNotNil(reportRange)
        XCTAssertLessThan(
            faqRange!.lowerBound, reportRange!.lowerBound,
            "Common Questions should be the first row in SUPPORT."
        )
    }

    // MARK: - Helpers

    private func sourceSection(in source: String, anchor: String) throws -> String {
        guard let anchorRange = source.range(of: anchor) else {
            XCTFail("Missing expected source anchor: \(anchor)")
            return ""
        }
        let body = source[anchorRange.lowerBound...]
        guard let endRange = body.range(of: "\n                }") else {
            XCTFail("Could not locate the end of the section for anchor: \(anchor)")
            return ""
        }
        return String(body[..<endRange.lowerBound])
    }

    private func settingsSourcePath() -> String {
        #if os(Windows)
        return "SmartSpeedCompanion\\Views\\Settings\\SettingsView.swift"
        #else
        return "SmartSpeedCompanion/Views/Settings/SettingsView.swift"
        #endif
    }
}
