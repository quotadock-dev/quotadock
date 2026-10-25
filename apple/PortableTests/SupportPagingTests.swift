import Foundation
import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class SupportPagingTests: XCTestCase {
    private let stamp = "2026-10-21T12:34:56.123001"
    private func id(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012x", n) }
    private func row(_ n: Int, timestamp: String? = nil, staff: Bool = false, status: String = "open") -> [String: Any] {
        var result: [String: Any] = ["id": id(n), "subject": "Ticket \(n)", "category": "general", "status": status,
                                   "createdAt": (timestamp ?? stamp) + "+00:00", "updatedAt": stamp + "+00:00"]
        if staff { result["ownerId"] = id(1000); result["assigneeId"] = NSNull() }
        return result
    }
    private func page(_ rows: [[String: Any]], cursor: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tickets": rows, "nextCursor": cursor as Any? ?? NSNull()])
    }
    private func cursor(_ n: Int) -> String { stamp + "Z|" + id(n) }

    func testCustomerTraversesBeyondFiftyAndReturnsToLatestWithoutAccumulation() throws {
        var pager = CloudSupportPager()
        let latest = try pager.begin()
        try pager.finish(page((2...51).reversed().map { row($0) }, cursor: cursor(2)), read: latest)
        XCTAssertEqual(pager.tickets.count, 50)
        XCTAssertEqual(pager.tickets.first?.subject, "Ticket 51")
        let older = try pager.begin(older: true)
        XCTAssertTrue(pager.tickets.isEmpty)
        XCTAssertNil(pager.nextCursor)
        XCTAssertEqual(older.before, cursor(2))
        try pager.finish(page([row(1)]), read: older)
        XCTAssertEqual(pager.tickets.map(\.subject), ["Ticket 1"])
        XCTAssertTrue(pager.loaded)
        XCTAssertNil(pager.nextCursor)
        XCTAssertThrowsError(try pager.begin(older: true))
        let reset = try pager.begin()
        XCTAssertNil(reset.before)
        try pager.finish(page([row(52)]), read: reset)
        XCTAssertEqual(pager.tickets.map(\.subject), ["Ticket 52"])
    }

    func testMicrosecondsTakePrecedenceOverUUIDAndCursorRoundTripsOnceEncoded() throws {
        var pager = CloudSupportPager()
        let first = try pager.begin(staff: true, status: "waiting")
        let precise = "2026-10-21T12:34:56.123999Z|" + id(1)
        try pager.finish(page([row(1, timestamp: "2026-10-21T12:34:56.123999", staff: true, status: "waiting")], cursor: precise), read: first)
        XCTAssertThrowsError(try pager.begin(older: true, staff: true, status: "open"))
        XCTAssertThrowsError(try pager.begin(older: true))
        let next = try pager.begin(older: true, staff: true, status: "waiting")
        let components = try XCTUnwrap(URLComponents(string: next.path))
        XCTAssertEqual(components.path, "v2/admin/tickets/page")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "before" })?.value, precise)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "status" })?.value, "waiting")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "50")
        XCTAssertTrue(next.path.contains("%7C"))
        try pager.finish(page([row(999, staff: true, status: "waiting"), row(998, staff: true, status: "waiting")]), read: next)
        XCTAssertEqual(pager.tickets.map(\.subject), ["Ticket 999", "Ticket 998"])
        XCTAssertEqual(pager.tickets.first?.createdAt, stamp + "+00:00")
        XCTAssertEqual(pager.tickets.first?.ownerId, UUID(uuidString: id(1000)))
        XCTAssertNil(pager.tickets.first?.assigneeId)
    }

    func testFailedOlderClearsPayloadAndRetriesSamePositionNotLatestOrNext() throws {
        var pager = CloudSupportPager()
        let first = try pager.begin()
        try pager.finish(page([row(8)], cursor: cursor(8)), read: first)
        let older = try pager.begin(older: true)
        pager.fail(older)
        XCTAssertTrue(pager.tickets.isEmpty)
        XCTAssertFalse(pager.loaded)
        XCTAssertTrue(pager.failed)
        XCTAssertNil(pager.nextCursor)
        let retry = try pager.begin(retry: true)
        XCTAssertEqual(retry.path, older.path)
        XCTAssertEqual(retry.before, cursor(8))
        try pager.finish(page([]), read: retry)
        XCTAssertTrue(pager.loaded)
        XCTAssertFalse(pager.failed)
        XCTAssertNil(pager.nextCursor)
        pager.reset()
        let latest = try pager.begin()
        pager.fail(latest)
        XCTAssertNil(try pager.begin(retry: true).before)
        var filtered = CloudSupportPager()
        let read = try filtered.begin(staff: true, status: "open")
        filtered.fail(read)
        XCTAssertThrowsError(try filtered.begin(retry: true, staff: true, status: "resolved"))
        XCTAssertThrowsError(try filtered.begin(retry: true))
        XCTAssertEqual(try filtered.begin(retry: true, staff: true, status: "open").path, read.path)
    }

    func testResetFilterChangeAndNewReadRejectLateSuccessAndFailure() throws {
        var pager = CloudSupportPager()
        let old = try pager.begin(staff: true, status: "open")
        pager.reset()
        let fresh = try pager.begin(staff: true, status: "resolved")
        XCTAssertThrowsError(try pager.finish(page([row(1, staff: true)]), read: old)) { XCTAssertTrue($0 is CancellationError) }
        pager.fail(old)
        XCTAssertFalse(pager.failed)
        try pager.finish(page([row(2, staff: true, status: "resolved")]), read: fresh)
        XCTAssertEqual(pager.tickets.map(\.subject), ["Ticket 2"])
        XCTAssertThrowsError(try pager.finish(page([]), read: old))
        pager.reset()
        XCTAssertTrue(pager.tickets.isEmpty)
        XCTAssertNil(pager.nextCursor)
        XCTAssertThrowsError(try pager.begin(retry: true, staff: true, status: "resolved"))
        XCTAssertThrowsError(try pager.begin(status: "open"))
        XCTAssertThrowsError(try pager.begin(staff: true, status: "all"))
    }

    func testMalformedPagesNeverPublishOrInventEndOfList() throws {
        let invalid = [
            Data("{\"tickets\":[]}".utf8), Data("{\"tickets\":[],\"nextCursor\":1}".utf8),
            try page([], cursor: cursor(1)), try page([row(1)], cursor: cursor(2)),
            try page([row(2), row(2)]), try page([row(1), row(2)]),
            try page((1...51).reversed().map { row($0) }),
            try page([row(1, timestamp: "2026-02-30T12:34:56.123001")]),
            try page([row(1, status: "unknown")]), try page([row(1, staff: true)]),
            Data(repeating: 32, count: 256 * 1024 + 1)
        ]
        for data in invalid {
            var pager = CloudSupportPager()
            let read = try pager.begin()
            XCTAssertThrowsError(try pager.finish(data, read: read))
            pager.fail(read)
            XCTAssertTrue(pager.tickets.isEmpty)
            XCTAssertFalse(pager.loaded)
            XCTAssertTrue(pager.failed)
        }
        var pager = CloudSupportPager()
        let first = try pager.begin()
        try pager.finish(page([row(4)], cursor: cursor(4)), read: first)
        let second = try pager.begin(older: true)
        XCTAssertThrowsError(try pager.finish(page([row(4)], cursor: cursor(4)), read: second))
        var staff = CloudSupportPager()
        let filtered = try staff.begin(staff: true, status: "waiting")
        XCTAssertThrowsError(try staff.finish(page([row(1, staff: true)]), read: filtered))
        XCTAssertThrowsError(try staff.finish(page([row(1)]), read: filtered))
    }

    func testCursorRejectsNoncanonicalAndInvalidDatesWithoutLosingPrecision() throws {
        let canonical = cursor(0xabcdef)
        try SupportCursor.validate(canonical)
        for value in [canonical.uppercased(), canonical.replacingOccurrences(of: ".123001Z", with: ".123Z"),
                      canonical.replacingOccurrences(of: "Z|", with: "+00:00|"),
                      canonical.replacingOccurrences(of: "2026-10-21", with: "2026-02-30"),
                      canonical.replacingOccurrences(of: "2026-", with: "0000-"),
                      canonical.replacingOccurrences(of: "12:34:56", with: "24:00:00"),
                      canonical + "x", "", String(repeating: "a", count: 5000)] {
            XCTAssertThrowsError(try SupportCursor.validate(value), value)
        }
        XCTAssertEqual(try SupportCursor.timestamp("2024-02-29T12:34:56.1+00:00"), "2024-02-29T12:34:56.100000Z")
        XCTAssertEqual(try SupportCursor.timestamp("2026-10-21T12:34:56Z"), "2026-10-21T12:34:56.000000Z")
    }
}
