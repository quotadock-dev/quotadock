import Foundation

struct CloudSupportTicket: Decodable, Identifiable {
    let id: UUID
    let subject: String
    let category: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let ownerId: UUID?
    let assigneeId: UUID?
}

// Keep six fractional digits as text: Date/Snapshot's millisecond projection
// cannot order tickets created within the same millisecond.
enum SupportCursor {
    static func timestamp(_ value: String) throws -> String {
        let pattern = #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|\+00:00)\z"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              !value.hasPrefix("0000-") else { throw SnapshotError.invalid }
        let whole = String(value.prefix(19))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: whole + "Z"), formatter.string(from: date) == whole + "Z" else {
            throw SnapshotError.invalid
        }
        let suffix = value.dropFirst(19).replacingOccurrences(of: "+00:00", with: "").replacingOccurrences(of: "Z", with: "")
        let fraction = suffix.isEmpty ? "" : String(suffix.dropFirst())
        return whole + "." + fraction + String(repeating: "0", count: 6 - fraction.count) + "Z"
    }

    static func validate(_ value: String) throws {
        guard value.utf8.count == 64 else { throw SnapshotError.invalid }
        let parts = value.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, try timestamp(String(parts[0])) == parts[0],
              let id = UUID(uuidString: String(parts[1])), id.uuidString.lowercased() == parts[1] else {
            throw SnapshotError.invalid
        }
    }

    static func position(_ ticket: CloudSupportTicket) throws -> String {
        try timestamp(ticket.createdAt) + "|" + ticket.id.uuidString.lowercased()
    }
}

// One bounded page replaces the previous one. Old assignments/statuses are not
// accumulated across non-frozen reads. Only explicit requests advance the cursor.
struct CloudSupportPager {
    struct Read: Equatable {
        let generation: UUID
        let path: String
        let before: String?
        let staff: Bool
        let status: String?
    }
    private(set) var tickets: [CloudSupportTicket] = []
    private(set) var nextCursor: String?
    private(set) var loaded = false
    private(set) var failed = false
    private var lastRead: Read?
    private var active: Read?

    mutating func reset() { self = Self() }

    mutating func begin(older: Bool = false, retry: Bool = false, staff: Bool = false, status: String? = nil) throws -> Read {
        guard !(older && retry), !older || nextCursor != nil,
              status == nil || (staff && ["open", "waiting", "resolved"].contains(status!)) else { throw SnapshotError.invalid }
        if older || retry {
            guard let lastRead, lastRead.staff == staff, lastRead.status == status,
                  !retry || failed else { throw SnapshotError.invalid }
        }
        let before = retry ? lastRead?.before : older ? nextCursor : nil
        if let before { try SupportCursor.validate(before) }
        var components = URLComponents()
        components.path = staff ? "v2/admin/tickets/page" : "v2/support/tickets/page"
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        if let before { components.queryItems?.append(URLQueryItem(name: "before", value: before)) }
        if let status { components.queryItems?.append(URLQueryItem(name: "status", value: status)) }
        let read = Read(generation: UUID(), path: components.string!, before: before, staff: staff, status: status)
        tickets = []; loaded = false; failed = false; nextCursor = nil; lastRead = nil
        active = read
        return read
    }

    mutating func finish(_ data: Data, read: Read) throws {
        guard active == read else { throw CancellationError() }
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["tickets", "nextCursor"]),
              let rows = root["tickets"] as? [[String: Any]], rows.count <= 50 else { throw SnapshotError.invalid }
        struct Page: Decodable { let tickets: [CloudSupportTicket]; let nextCursor: String? }
        let page = try JSONDecoder().decode(Page.self, from: data)
        var previous = read.before
        var ids = Set<UUID>()
        for (ticket, row) in zip(page.tickets, rows) {
            let keys: Set<String> = ["id", "subject", "category", "status", "createdAt", "updatedAt"]
            guard Set(row.keys) == (read.staff ? keys.union(["ownerId", "assigneeId"]) : keys),
                  !read.staff || ticket.ownerId != nil,
                  ["open", "waiting", "resolved"].contains(ticket.status),
                  read.status == nil || ticket.status == read.status,
                  ids.insert(ticket.id).inserted else { throw SnapshotError.invalid }
            let position = try SupportCursor.position(ticket)
            guard previous.map({ position < $0 }) ?? true else { throw SnapshotError.invalid }
            previous = position
        }
        if let cursor = page.nextCursor {
            try SupportCursor.validate(cursor)
            guard let last = page.tickets.last, cursor == (try SupportCursor.position(last)) else { throw SnapshotError.invalid }
        }
        tickets = page.tickets; nextCursor = page.nextCursor; loaded = true; failed = false; active = nil; lastRead = read
    }

    mutating func fail(_ read: Read) {
        guard active == read else { return }
        tickets = []; nextCursor = nil; loaded = false; failed = true; active = nil; lastRead = read
    }
}
