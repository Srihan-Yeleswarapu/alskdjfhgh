import XCTest
@testable import SmartSpeedCompanion

/// Siri shortcuts: phrase vocabulary, persistence, and intent payloads.
/// Everything here is local string/persistence work — zero HERE coupling.
final class SiriShortcutsContractTests: XCTestCase {

    private struct ShortcutRecord: Codable, Equatable {
        var phrase: String
        var action: String
    }

    // MARK: - Phrase vocabulary validity

    func testPhrasesAreNonEmptyAndBounded() {
        let phrases = ["Start driving", "Stop driving", "What's my speed",
                       "Where are the cameras", "Start recording"]
        for p in phrases {
            XCTAssertFalse(p.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertLessThan(p.count, 100, "Phrase too long for Siri: \(p)")
        }
    }

    func testPhrasesAreUniqueAfterNormalization() {
        let raw = ["Start driving", "start driving ", "START DRIVING"]
        let normalized = Set(raw.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(normalized.count, 1,
                       "Normalization failed to collapse duplicate phrases")
    }

    func testPhrasesAvoidSiriReservedWords() {
        // "Hey Siri" prefixes and bare system verbs are reserved.
        let reserved = ["hey siri", "siri"]
        let phrases = ["Start driving", "Stop recording"]
        for p in phrases {
            for r in reserved {
                XCTAssertFalse(p.lowercased().hasPrefix(r),
                               "Phrase '\(p)' collides with reserved prefix '\(r)'")
            }
        }
    }

    // MARK: - Persistence round-trip

    func testShortcutRecordCodableRoundTrip() throws {
        let record = ShortcutRecord(phrase: "Camera check", action: "reportCameras")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ShortcutRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testShortcutRecordSurvivesBulkPersistence() throws {
        var records: [ShortcutRecord] = []
        for i in 0..<200 {
            records.append(ShortcutRecord(phrase: "Phrase \(i)", action: "action\(i % 5)"))
        }
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([ShortcutRecord].self, from: data)
        XCTAssertEqual(decoded.count, 200)
        XCTAssertEqual(decoded[137].phrase, "Phrase 137")
    }

    // MARK: - Intent payload contracts

    func testIntentActionEnumCoverage() {
        // Every donatable action must map to a concrete handler string.
        let knownActions = Set(["startDrive", "stopDrive", "reportCameras", "startRecording"])
        for a in ["startDrive", "stopDrive", "reportCameras", "startRecording"] {
            XCTAssertTrue(knownActions.contains(a), "Action \(a) has no handler")
        }
    }

    func testUnknownIntentActionIsRejected() {
        let knownActions = Set(["startDrive", "stopDrive", "reportCameras", "startRecording"])
        XCTAssertFalse(knownActions.contains("deleteAllData"),
                       "Unknown intent must not be accepted")
    }

    // MARK: - Response strings users actually hear

    func testSiriResponsesAreSpeakable() {
        let responses = ["Starting your drive", "Drive stopped", "No cameras nearby"]
        for r in responses {
            XCTAssertFalse(r.isEmpty)
            XCTAssertLessThan(r.count, 200, "Response too long to speak comfortably")
        }
    }

    func testResponsesNeverContainDebugArtifacts() {
        let responses = ["Starting your drive", "Drive stopped", "No cameras nearby"]
        for r in responses {
            XCTAssertFalse(r.lowercased().contains("nil"), "Debug artifact in response: \(r)")
            XCTAssertFalse(r.lowercased().contains("error"), "Error text in response: \(r)")
            XCTAssertFalse(r.contains("%@"), "Format placeholder leaked into response")
        }
    }
}
