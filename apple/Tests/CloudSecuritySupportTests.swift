import XCTest
@testable import QuotaDock

final class CloudSecuritySupportTests: XCTestCase {
    @MainActor
    func testHistoryRejectsDisconnectedReadsAndConsentChanges() async {
        let model = CloudModel()
        model.session = nil
        let slot = CloudAccount(id: UUID(), provider: .codex)
        model.slots = [slot]
        do {
            _ = try await model.readHistorySettings()
            XCTFail("Disconnected history must not be read")
        } catch { XCTAssertTrue(error is CancellationError) }
        for enabled in [true, false] {
            do {
                _ = try await model.changeHistory(enabled: enabled, exactToken: "synthetic-stale-session")
                XCTFail("A disconnected confirmation must not change consent")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        do {
            _ = try await model.readHistoryPage(account: slot)
            XCTFail("A retained slot does not authorize history")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLoginChallengeRejectsExpiredAndMalformedTokens() throws {
        let base = URL(string: "https://example.com")!
        func response(_ token: String, _ expiry: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["mfaRequired": true, "challenge": token, "expiresAt": expiry])
        }
        let token = String(repeating: "a", count: 43)
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
        let valid = try XCTUnwrap(CloudMFAChallenge.decodeIfRequired(response(token, future), base: base))
        XCTAssertEqual(valid.challenge, token)
        XCTAssertEqual(valid.base, base)
        XCTAssertThrowsError(try CloudMFAChallenge.decodeIfRequired(response(token, "2020-01-01T00:00:00Z"), base: base))
        XCTAssertThrowsError(try CloudMFAChallenge.decodeIfRequired(response(String(repeating: "/", count: 43), future), base: base))
        XCTAssertNil(try CloudMFAChallenge.decodeIfRequired(Data("{\"sessionToken\":\"legacy\"}".utf8), base: base))
    }

    func testRecoveryCodesRequireTenDistinctValuesAndReauthenticationOnConfirmation() throws {
        let codes = (0..<10).map { "recovery-\($0)" }
        try CloudRecoveryResult(recoveryCodes: codes, reauthenticate: true).validate(requireReauthentication: true)
        try CloudRecoveryResult(recoveryCodes: codes, reauthenticate: nil).validate(requireReauthentication: false)
        XCTAssertThrowsError(try CloudRecoveryResult(recoveryCodes: codes, reauthenticate: nil).validate(requireReauthentication: true))
        XCTAssertThrowsError(try CloudRecoveryResult(recoveryCodes: Array(repeating: "duplicate", count: 10), reauthenticate: true).validate(requireReauthentication: true))
    }

    func testEnrollmentMustBeRestrictedUnexpiredAndAuthenticatorURI() throws {
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
        try CloudEnrollment(enrollmentToken: "restricted", otpauthUri: "otpauth://totp/Allowmark?secret=EXAMPLE", expiresAt: expiry, restricted: true).validate()
        XCTAssertThrowsError(try CloudEnrollment(enrollmentToken: "restricted", otpauthUri: "https://example.com", expiresAt: expiry, restricted: true).validate())
        XCTAssertThrowsError(try CloudEnrollment(enrollmentToken: "restricted", otpauthUri: "otpauth://totp/Allowmark", expiresAt: expiry, restricted: false).validate())
        XCTAssertThrowsError(try CloudEnrollment(enrollmentToken: "restricted", otpauthUri: "otpauth://totp/Allowmark", expiresAt: "2020-01-01T00:00:00Z", restricted: true).validate())
    }

    func testSupportConversationUsesDatabaseMessageIdentifiers() throws {
        let data = Data("""
        {"id":2147483649,"message":"Collector offline","staff":false,"internal":false,"createdAt":"2026-10-21T06:00:00Z"}
        """.utf8)
        let message = try JSONDecoder().decode(CloudSupportMessage.self, from: data)
        XCTAssertEqual(message.id, 2_147_483_649)
        XCTAssertEqual(message.message, "Collector offline")
        XCTAssertFalse(message.internal)
    }
}
