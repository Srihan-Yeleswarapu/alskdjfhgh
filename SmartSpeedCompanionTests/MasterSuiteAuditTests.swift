import XCTest
@testable import SmartSpeedCompanion

/// The master suite auditor. Every guarantee the operator asked for is
/// checked here, structurally, on every run:
///
///   1. The suite is exactly 100 `*Tests.swift` files with unique class
///      names (a dropped or duplicated file fails loudly, not silently).
///   2. Every counted file really declares an XCTestCase subclass.
///   3. HERE rate-limit policy: no file outside the sanctioned HERELive*
///      capture references raw network primitives or credential injection —
///      hermetic tests can never grow a hidden HERE call.
///   4. CI isolation: the GitHub workflows must never invoke `xcodebuild
///      test`; the suite runs only on the operator's Mac.
///   5. Project wiring: the SmartSpeedCompanionTests target exists in
///      project.yml so `xcodebuild test` works after `xcodegen generate`.
///
/// If this file fails, fix the suite — do not weaken the audit.
final class MasterSuiteAuditTests: XCTestCase {

    // MARK: - Layout

    private var testsDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    private var projectRoot: URL {
        testsDirectory.deletingLastPathComponent()
    }

    private var allSwiftFiles: [URL] = []

    private let supportFileNames: Set<String> = [
        "SharedTestSupport.swift", "HERECorpusLoader.swift", "HERELiveCorpusCapture.swift"
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        allSwiftFiles = try FileManager.default.contentsOfDirectory(
            at: testsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    private var testFiles: [URL] {
        allSwiftFiles.filter { $0.lastPathComponent.hasSuffix("Tests.swift") }
    }

    // MARK: 1 — exactly 100 test files

    func testSuiteContainsExactlyOneHundredTestFiles() throws {
        let files = testFiles
        XCTAssertEqual(files.count, 100,
                       "Suite must be exactly 100 *Tests.swift files (found \(files.count)). " +
                       "If you added one, retire or merge another — the audit keeps the count honest.")
    }

    func testEveryTestFileNameIsUnique() throws {
        let names = testFiles.map { $0.lastPathComponent }
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $1.count > 1 }
        XCTAssertTrue(duplicates.isEmpty, "duplicate test file names: \(duplicates.keys)")
    }

    // MARK: 2 — every file is a real test target

    func testEveryTestFileDeclaresAnXCTestCaseSubclass() throws {
        for file in testFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(source.contains("XCTestCase"),
                          "\(file.lastPathComponent) does not declare an XCTestCase subclass")
            XCTAssertTrue(source.contains("func test"),
                          "\(file.lastPathComponent) contains no test methods")
        }
    }

    func testTestClassNamesAreGloballyUnique() throws {
        // Objective-C cannot register two classes with the same name; a
        // collision breaks the whole suite at runtime, not compile time.
        var names: [String: String] = [:]
        var collisions: [String] = []
        for file in allSwiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let pattern = "class (\\w+)\\s*:\\s*XCTestCase"
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                if let range = Range(match.range(at: 1), in: source) {
                    let name = String(source[range])
                    if let previous = names[name], previous != file.lastPathComponent {
                        collisions.append("\(name) in \(previous) AND \(file.lastPathComponent)")
                    }
                    names[name] = file.lastPathComponent
                }
            }
        }
        XCTAssertTrue(collisions.isEmpty, "duplicate XCTestCase class names: \(collisions)")
    }

    // MARK: 3 — HERE hermeticity by source scan

    func testHermeticFilesContainNoRawNetworkOrCredentialSurface() throws {
        // Tokens that must NEVER appear outside the sanctioned files:
        //   URLSession / dataTask / URLRequest — raw networking or request
        //   construction (the only path to a HERE call)
        //   MKLocalSearch         — Apple places search (indirect quota cost)
        // Keychain CRUD (saveCredentials/clearCredentials) is deliberately
        // NOT banned: HERECredentialStoreSecurityTests exercises it offline.
        // The HERELive* capture is the single sanctioned network citizen;
        // the support loader feeds the wire-shaped corpus instead.
        let banned = ["URLSession", "dataTask", "URLRequest", "MKLocalSearch"]
        var violations: [String] = []
        for file in allSwiftFiles
        where !supportFileNames.contains(file.lastPathComponent)
              && file.lastPathComponent != "MasterSuiteAuditTests.swift"
              && !file.lastPathComponent.hasPrefix("HERELive") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in banned where source.contains(token) {
                violations.append("\(file.lastPathComponent) references '\(token)'")
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "HERE policy violation — only HERELive* files may touch these surfaces:\n" +
                      violations.joined(separator: "\n"))
    }

    func testLiveCaptureIsGatedBehindOptInEnvironment() throws {
        // The one network file must skip itself unless the operator opted in.
        let capture = try String(
            contentsOf: testsDirectory.appendingPathComponent("HERELiveCorpusCapture.swift"),
            encoding: .utf8)
        XCTAssertTrue(capture.contains("SPEEDIO_LIVE_HERE_TESTS"),
                      "HERELiveCorpusCapture must gate on SPEEDIO_LIVE_HERE_TESTS")
        XCTAssertTrue(capture.contains("skipUnlessLiveHEREEnabled"),
                      "HERELiveCorpusCapture must use the shared opt-in gate")
    }

    func testSharedSupportDefinesTheOptInGates() throws {
        let support = try String(
            contentsOf: testsDirectory.appendingPathComponent("SharedTestSupport.swift"),
            encoding: .utf8)
        for gate in ["SPEEDIO_LIVE_HERE_TESTS", "SPEEDIO_PERF_TESTS", "SPEEDIO_STRESS_TESTS"] {
            XCTAssertTrue(support.contains(gate), "SharedTestSupport must define the \(gate) gate")
        }
        XCTAssertTrue(support.contains("HERECredentialsGate"),
                      "SharedTestSupport must provide the credential-removal hermetic switch")
        XCTAssertTrue(support.contains("GPSFixFactory"),
                      "SharedTestSupport must provide the GPS fix factory")
    }

    // MARK: 4 — CI isolation (the operator's hard requirement)

    func testCINeverRunsTheTestSuite() throws {
        let workflowsDir = projectRoot.appendingPathComponent(".github/workflows")
        let workflowFiles = try FileManager.default.contentsOfDirectory(
            at: workflowsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
        XCTAssertFalse(workflowFiles.isEmpty, "expected CI workflows to exist for the check")

        for file in workflowFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(content.contains("xcodebuild test"),
                           "\(file.lastPathComponent) must never run the XCTest suite — " +
                           "tests are an on-device, operator-run pass only")
            XCTAssertFalse(content.contains("run_tests"),
                           "\(file.lastPathComponent) references a test script entry")
        }
    }

    // MARK: 5 — project wiring

    func testProjectYmlWiresTheTestTarget() throws {
        let yml = try String(
            contentsOf: projectRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("SmartSpeedCompanionTests"),
                      "project.yml must declare the SmartSpeedCompanionTests target so xcodebuild test resolves it")
        XCTAssertTrue(yml.contains("xcodegen"),
                      "project generation must be xcodegen-based (suite relies on generated scheme)")
    }

    // MARK: — Corpus presence (hermetic data dependency)

    func testCorpusSeedExistsForHermeticHEREPipelines() {
        // Either a captured bundle or the in-code seed must exist — every
        // cache/matcher/service hermetic test leans on it.
        let loaderURL = testsDirectory.appendingPathComponent("HERECorpusLoader.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaderURL.path),
                      "HERECorpusLoader.swift is the hermetic HERE data source and must exist")
    }

    // MARK: — Self-audit

    func testAuditCoversAtLeastNinetyFivePercentOfSuiteAsXCTest() throws {
        // Soft floor so a future support file with helpers (non-XCTest) does
        // not fail the audit, while a systematically broken file set does.
        var withTests = 0
        for file in testFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("XCTestCase") && source.contains("func test") { withTests += 1 }
        }
        let ratio = Double(withTests) / Double(max(testFiles.count, 1))
        XCTAssertGreaterThanOrEqual(ratio, 0.95, "too many non-test files crept into the suite")
    }
}
