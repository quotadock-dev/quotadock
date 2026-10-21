import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class WatchTransferTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1234)

    private func quota(_ remaining: Double = 72) -> Snapshot {
        Snapshot(schemaVersion: 1, generatedAt: date, demo: false, providers: [
            Provider(id: .codex, name: "private-account-id", plan: "private-token",
                     state: .available, source: .codexbar, message: "raw diagnostic",
                     observedAt: date, windows: [
                        QuotaWindow(id: "primary", label: "Session",
                                    remainingPercent: remaining, resetsAt: nil)
                     ])
        ])
    }

    private var clear: Snapshot {
        Snapshot(schemaVersion: 1, generatedAt: date, demo: false, providers: [])
    }

    private func decoded(_ transfer: WatchTransfer) throws -> Snapshot {
        try Snapshot.decode(XCTUnwrap(transfer.pending))
    }

    func testNewestQuotaAndClearReplacePendingIntention() throws {
        var transfer = WatchTransfer()
        transfer.enqueue(quota())
        transfer.enqueue(quota(0))
        XCTAssertEqual(try decoded(transfer), quota(0).sanitized)
        transfer.enqueue(clear)
        XCTAssertEqual(try decoded(transfer), clear)
        transfer.enqueue(quota(28))
        XCTAssertEqual(try decoded(transfer), quota(28).sanitized)
    }

    func testActivationUsesDiskInsteadOfStalePendingQuotaOrClear() throws {
        var transfer = WatchTransfer()
        transfer.enqueue(quota())
        transfer.reconcile(phoneSnapshot: nil, at: date)
        XCTAssertEqual(try decoded(transfer), clear)
        transfer.enqueue(clear)
        transfer.reconcile(phoneSnapshot: quota(19), at: date)
        XCTAssertEqual(try decoded(transfer), quota(19).sanitized)
        transfer.enqueue(quota(90))
        transfer.reconcile(phoneSnapshot: quota(37), at: date)
        XCTAssertEqual(try decoded(transfer), quota(37).sanitized)
    }

    func testRestartWithoutPhoneCachePublishesNonDemoEmptySnapshot() throws {
        var transfer = WatchTransfer()
        XCTAssertNil(transfer.pending)
        transfer.reconcile(phoneSnapshot: nil, at: date)
        let snapshot = try decoded(transfer)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.generatedAt, date)
        XCTAssertFalse(snapshot.demo)
        XCTAssertTrue(snapshot.providers.isEmpty)
    }

    func testPersistedDemoCannotBecomeCompanionAuthority() throws {
        var transfer = WatchTransfer()
        transfer.reconcile(phoneSnapshot: .preview, at: date)
        XCTAssertEqual(try decoded(transfer), clear)
        let mixed = Snapshot(schemaVersion: 1, generatedAt: date, demo: false,
                             providers: Snapshot.preview.providers)
        transfer.reconcile(phoneSnapshot: mixed, at: date)
        XCTAssertEqual(try decoded(transfer), clear)
        transfer.enqueue(.preview)
        XCTAssertNil(transfer.pending)
    }

    func testTransferContainsOnlySanitizedQuotaAndOriginalObservation() throws {
        var transfer = WatchTransfer()
        transfer.reconcile(phoneSnapshot: quota(), at: date)
        let data = try XCTUnwrap(transfer.pending)
        XCTAssertLessThanOrEqual(data.count, 256 * 1024)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["private-account-id", "private-token", "raw diagnostic", "accountId", "sessionToken"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertEqual(try decoded(transfer), quota().sanitized)
        XCTAssertEqual(try decoded(transfer).providers.first?.observedAt, date)
        transfer.accepted()
        XCTAssertNil(transfer.pending)
    }

    func testInvalidNewestInputCannotResurrectOlderPendingQuota() {
        var transfer = WatchTransfer()
        transfer.enqueue(quota())
        transfer.enqueue(quota(101))
        XCTAssertNil(transfer.pending)
        transfer.enqueue(quota())
        transfer.reconcile(phoneSnapshot: Snapshot(schemaVersion: 2, generatedAt: date,
                                                   demo: false, providers: []), at: date)
        XCTAssertNil(transfer.pending)
    }
}
