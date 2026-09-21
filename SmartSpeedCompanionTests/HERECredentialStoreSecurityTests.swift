import XCTest
@testable import SmartSpeedCompanion

/// Credential stores: HERE's Keychain-backed store is the gate that keeps
/// hermetic tests hermetic (no credentials → providers short-circuit before
/// building URLs) and keeps live tests alive. These tests verify the
/// save/load/clear lifecycle and the has* semantics both the app and the
/// test suite rely on. Geoapify's store is covered identically.
final class HERECredentialStoreSecurityTests: XCTestCase {

    private var savedCredentials: HERECredentialStore.Credentials?
    private var hadCredentials = false

    override func setUp() {
        super.setUp()
        if let creds = HERECredentialStore.shared.loadCredentials() {
            hadCredentials = true
            savedCredentials = creds
            HERECredentialStore.shared.clearCredentials()
        }
    }

    override func tearDown() {
        HERECredentialStore.shared.clearCredentials()
        if hadCredentials, let creds = savedCredentials {
            HERECredentialStore.shared.saveCredentials(accessKeyId: creds.accessKeyId,
                                                       accessKeySecret: creds.accessKeySecret)
        }
        super.tearDown()
    }

    // MARK: - HERE store lifecycle

    func testLoadWithoutCredentialsReturnsNil() {
        HERECredentialStore.shared.clearCredentials()
        XCTAssertNil(HERECredentialStore.shared.loadCredentials(),
                     "Empty store must load nil — this nil is the hermetic-test switch")
    }

    func testSaveThenLoadRoundTrip() {
        HERECredentialStore.shared.saveCredentials(accessKeyId: "test-key-id",
                                                   accessKeySecret: "test-key-secret")
        let creds = HERECredentialStore.shared.loadCredentials()
        XCTAssertNotNil(creds)
        XCTAssertEqual(creds?.accessKeyId, "test-key-id")
        XCTAssertEqual(creds?.accessKeySecret, "test-key-secret")
    }

    func testOverwriteReplacesNotAppends() {
        HERECredentialStore.shared.saveCredentials(accessKeyId: "first", accessKeySecret: "s1")
        HERECredentialStore.shared.saveCredentials(accessKeyId: "second", accessKeySecret: "s2")
        XCTAssertEqual(HERECredentialStore.shared.loadCredentials()?.accessKeyId, "second")
    }

    func testClearRemovesEverything() {
        HERECredentialStore.shared.saveCredentials(accessKeyId: "k", accessKeySecret: "s")
        HERECredentialStore.shared.clearCredentials()
        XCTAssertNil(HERECredentialStore.shared.loadCredentials())
    }

    func testHasCredentialsTracksState() {
        HERECredentialStore.shared.clearCredentials()
        // hasCredentials may consult the same backing store; after save it
        // must flip true.
        HERECredentialStore.shared.saveCredentials(accessKeyId: "k", accessKeySecret: "s")
        XCTAssertTrue(HERECredentialStore.shared.hasCredentials())
        HERECredentialStore.shared.clearCredentials()
    }

    func testEmptyKeyIsStillAStoredValue() {
        // The provider guards on `!creds.accessKeyId.isEmpty` separately —
        // an empty string must round-trip so the "configured but empty"
        // failure mode stays distinguishable from "not configured".
        HERECredentialStore.shared.saveCredentials(accessKeyId: "", accessKeySecret: "s")
        let creds = HERECredentialStore.shared.loadCredentials()
        XCTAssertEqual(creds?.accessKeyId, "", "Empty key must survive the round trip")
    }

    // MARK: - Provider behavior without credentials (hermetic proof)

    func testRESTProviderReturnsNilWithoutCredentials() async throws {
        HERECredentialStore.shared.clearCredentials()
        let provider = HERERestSpeedLimitProvider()
        let response = try await provider.fetchSpeedLimit(
            at: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
            heading: 90, forceRefresh: true
        )
        XCTAssertNil(response, "Missing credentials must short-circuit BEFORE any network work")
    }

    func testBatchProviderReturnsNilWithoutCredentials() async throws {
        HERECredentialStore.shared.clearCredentials()
        let provider = HERERouteMatchingBatchProvider()
        let response = try await provider.fetchSpeedLimit(
            at: CLLocationCoordinate2D(latitude: 33.3062, longitude: -111.8412),
            heading: 90, forceRefresh: true
        )
        XCTAssertNil(response)
    }

    // MARK: - Geoapify store

    func testGeoapifyKeyLifecycle() {
        let store = GeoapifyCredentialStore()
        let had = store.hasApiKey()
        let original = store.loadApiKey()
        defer {
            if let original { store.saveApiKey(original) } else { store.clearApiKey() }
            XCTAssertEqual(store.hasApiKey(), had, "Geocoder key state must be restored")
        }

        store.saveApiKey("geo-test-key")
        XCTAssertTrue(store.hasApiKey())
        XCTAssertEqual(store.loadApiKey(), "geo-test-key")
        store.clearApiKey()
        XCTAssertFalse(store.hasApiKey())
    }

    // MARK: - CryptoUtils (Sign in with Apple nonce path)

    func testRandomNonceLengthAndUniqueness() {
        let a = CryptoUtils.randomNonceString(length: 32)
        let b = CryptoUtils.randomNonceString(length: 32)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b, "Nonces must never repeat")
    }

    func testRandomNonceCustomLength() {
        XCTAssertEqual(CryptoUtils.randomNonceString(length: 16).count, 16)
        XCTAssertEqual(CryptoUtils.randomNonceString(length: 64).count, 64)
    }

    func testSHA256KnownVectors() {
        // NIST FIPS 180-4 test vectors.
        XCTAssertEqual(CryptoUtils.sha256(""), 
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(CryptoUtils.sha256("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256IsDeterministicAndLengthFixed() {
        let one = CryptoUtils.sha256("Speedio")
        let two = CryptoUtils.sha256("Speedio")
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.count, 64, "SHA-256 hex digest is 64 chars")
    }
}
