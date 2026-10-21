import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class BillingContractTests: XCTestCase {
    func testCatalogOriginAndPaidOnlyProducts() {
        let products = ["com.quotadock.app.plus.monthly", "com.quotadock.app.plus.annual",
                        "com.quotadock.app.pro.monthly", "com.quotadock.app.pro.annual"]
        XCTAssertEqual(Set(BillingPolicy.productIDs), Set(products))
        XCTAssertTrue(BillingPolicy.officialOrigin(URL(string: "https://usage.mvtp.cloud")!))
        for text in ["http://usage.mvtp.cloud", "https://usage.mvtp.cloud.evil.test", "https://example.com",
                     "https://usage.mvtp.cloud:444", "https://user@usage.mvtp.cloud",
                     "https://usage.mvtp.cloud/custom", "https://usage.mvtp.cloud?token=x"] {
            XCTAssertFalse(BillingPolicy.officialOrigin(URL(string: text)!))
        }
        for id in products + ["com.quotadock.app.plus.foreign"] {
            XCTAssertEqual(BillingPolicy.supports(productID: id, hasIntroductoryOffer: false),
                           products.contains(id))
            XCTAssertFalse(BillingPolicy.supports(productID: id, hasIntroductoryOffer: true))
        }
    }
}
