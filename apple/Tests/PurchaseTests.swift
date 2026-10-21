import XCTest
@testable import QuotaDock

final class PurchaseTests: XCTestCase {
    func testBindingRequiresVerifiedKnownSubscriptionAndExactOwner() {
        let account = UUID()
        let id = PurchasePolicy.productIDs[0]
        XCTAssertTrue(PurchasePolicy.eligible(productID: id, autoRenewable: true, verified: true, owner: account, account: account))
        for owner in [nil, UUID()] as [UUID?] {
            XCTAssertFalse(PurchasePolicy.eligible(productID: id, autoRenewable: true, verified: true, owner: owner, account: account))
        }
        XCTAssertFalse(PurchasePolicy.eligible(productID: "foreign", autoRenewable: true, verified: true, owner: account, account: account))
        XCTAssertFalse(PurchasePolicy.eligible(productID: id, autoRenewable: false, verified: true, owner: account, account: account))
        XCTAssertFalse(PurchasePolicy.eligible(productID: id, autoRenewable: true, verified: false, owner: account, account: account))
    }

    func testReceiptBoundaryIsUTF8AndBoundsSerializedRequest() throws {
        let body = try PurchasePolicy.receiptBody("signed.payload.signature")
        XCTAssertEqual(Set(body.keys), ["signedTransactionInfo"])
        XCTAssertEqual(body["signedTransactionInfo"] as? String, "signed.payload.signature")
        XCTAssertThrowsError(try PurchasePolicy.receiptBody(""))
        XCTAssertThrowsError(try PurchasePolicy.receiptBody(String(repeating: "a", count: 24_001)))
        XCTAssertThrowsError(try PurchasePolicy.receiptBody(String(repeating: "é", count: 12_001)))
        XCTAssertThrowsError(try PurchasePolicy.receiptBody(String(repeating: "\"", count: 12_000)))
        XCTAssertNoThrow(try PurchasePolicy.receiptBody(String(repeating: "a", count: 23_900)))
    }

    func testAcceptanceRequiresStructuralEntitlementAndFreeIsAccepted() throws {
        func decode(_ text: String) throws -> String { try PurchasePolicy.acceptedTier(Data(text.utf8)) }
        XCTAssertEqual(try decode("{\"tier\":\"free\",\"periodId\":null,\"expiresAt\":null}"), "free")
        for tier in ["plus", "pro"] {
            XCTAssertEqual(try decode("{\"tier\":\"\(tier)\",\"periodId\":\"period\",\"expiresAt\":\"2026-11-01T00:00:00.000Z\"}"), tier)
        }
        for text in ["{}", "{\"tier\":\"paid\",\"periodId\":null,\"expiresAt\":null}",
                     "{\"tier\":\"plus\",\"periodId\":null,\"expiresAt\":null}",
                     "{\"tier\":\"free\",\"periodId\":\"period\",\"expiresAt\":null}",
                     "{\"tier\":\"free\",\"periodId\":4,\"expiresAt\":null}",
                     "{\"tier\":\"free\",\"periodId\":null,\"expiresAt\":\"invalid\"}"] {
            XCTAssertThrowsError(try decode(text))
        }
    }

    @MainActor
    func testPurchasesRequireAllServerAuthorityAndLogoutClearsAvailability() throws {
        let model = PurchasesModel()
        let client = try CloudClient(baseURL: "https://usage.mvtp.cloud", token: String(repeating: "a", count: 43))
        let custom = try CloudClient(baseURL: "https://example.com", token: String(repeating: "a", count: 43))
        model.configure(client: custom, accountToken: UUID(), available: true, onVerified: {})
        XCTAssertFalse(model.available)
        for (client, token, enabled) in [(nil, UUID(), true), (client, nil, true), (client, UUID(), false)] as [(CloudClient?, UUID?, Bool)] {
            model.configure(client: client, accountToken: token, available: enabled, onVerified: {})
            XCTAssertFalse(model.available)
        }
        model.configure(client: client, accountToken: UUID(), available: true, onVerified: {})
        XCTAssertTrue(model.available)
        // Clear before yielding to StoreKit recovery: no receipt or network is exercised.
        model.configure(client: nil, accountToken: nil, available: false, onVerified: {})
        XCTAssertFalse(model.available)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.products.isEmpty)
        XCTAssertTrue(model.status.contains("unavailable"))
    }
}
