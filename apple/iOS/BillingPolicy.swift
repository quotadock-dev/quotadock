import Foundation

/// StoreKit-independent decisions; no local entitlement.
enum BillingPolicy {
    static let productIDs = ["com.quotadock.app.plus.monthly", "com.quotadock.app.pro.monthly",
                             "com.quotadock.app.plus.annual", "com.quotadock.app.pro.annual"]

    static func tier(_ id: String) -> String? {
        guard productIDs.contains(id) else { return nil }
        return id.contains(".plus.") ? "plus" : "pro"
    }

    static func annual(_ id: String) -> Bool { productIDs.contains(id) && id.hasSuffix(".annual") }

    static func officialOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "usage.mvtp.cloud"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    /// Paid subscriptions must not silently apply a configured introductory offer.
    static func supports(productID: String, hasIntroductoryOffer: Bool) -> Bool {
        productIDs.contains(productID) && !hasIntroductoryOffer
    }
}
