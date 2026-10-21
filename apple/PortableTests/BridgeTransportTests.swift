import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class BridgeTransportTests: XCTestCase {
    private func client() -> BridgeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeProtocol.self]
        return BridgeClient(session: URLSession(configuration: configuration))
    }

    private func failure(_ path: String, _ expected: BridgeTransportError) async throws {
        do {
            _ = try await client().fetch(Pairing(baseURL: "https://example.invalid/\(path)", token: "test-token"))
            XCTFail("Expected bounded transport failure")
        } catch { XCTAssertEqual(error as? BridgeTransportError, expected) }
    }

    func testTypedRejectionsAndGenericFailures() async throws {
        try await failure("401", .unauthorized)
        try await failure("403", .forbidden)
        for path in ["302", "500", "malformed", "oversize", "declared-oversize", "network"] {
            try await failure(path, .transport)
        }
    }

    func testPrefixHeadersCookieIsolationAndExactCap() async throws {
        for prefix in ["nested/prefix", "exact-cap"] {
            let snapshot = try await client().fetch(Pairing(baseURL: "https://example.invalid/\(prefix)", token: "test-token"))
            XCTAssertEqual(snapshot.schemaVersion, 1)
            XCTAssertTrue(snapshot.providers.isEmpty)
        }
    }

    func testRejectedAuthorityNeverStartsTransportAndAllowedAuthorityCanRead() async throws {
        do {
            _ = try await client().fetch(Pairing(baseURL: "https://example.invalid/must-not-start", token: "test-token"),
                authorityCheck: { throw SnapshotError.unpaired })
            XCTFail("A disconnected credential must not start a request")
        } catch { XCTAssertEqual(error as? BridgeTransportError, .transport) }
        let snapshot = try await client().fetch(Pairing(baseURL: "https://example.invalid/exact-cap", token: "test-token"),
            authorityCheck: {})
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertTrue(snapshot.providers.isEmpty)
    }

    func testAbsoluteDeadlineIncludesSilentHeadersAndSilentBody() async throws {
        for path in ["silent-headers", "silent-body"] {
            let start = ProcessInfo.processInfo.systemUptime
            try await failure(path, .transport)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 23)
        }
    }

    func testPrecancelledFetchDoesNotStartProtocol() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await failure("must-not-start", .transport)
        }
        try await task.value
    }

    func testCancellationInterruptsAnAlreadyStartedSilentRequest() async throws {
        let started = expectation(description: "Transport has started and remains silent")
        let observer = NotificationCenter.default.addObserver(forName: BridgeProtocol.cancellableStarted,
            object: nil, queue: nil) { _ in started.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let task = Task {
            try await client().fetch(Pairing(baseURL: "https://example.invalid/cancel-inflight", token: "test-token"))
        }
        await fulfillment(of: [started], timeout: 3)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a snapshot") }
        catch { XCTAssertEqual(error as? BridgeTransportError, .transport) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    func testPersistedValuesRejectUnsafeURLsAndTokensAndKeepPrefixes() throws {
        func decode(_ endpoint: String, _ token: String) throws -> Pairing {
            try JSONDecoder().decode(Pairing.self, from: JSONSerialization.data(withJSONObject:
                ["endpoint": endpoint, "token": token]))
        }
        for endpoint in ["http://example.invalid/v1/snapshot", "https://user:pass@example.invalid/v1/snapshot",
                         "https://example.invalid/v1/snapshot?q=x", "https://example.invalid/v1/snapshot#x", "https:///v1/snapshot",
                         "https://example.invalid/" + String(repeating: "a", count: 2048)] {
            XCTAssertThrowsError(try decode(endpoint, "test-token"))
        }
        XCTAssertThrowsError(try Pairing(baseURL: "https://example.invalid/" + String(repeating: "a", count: 2048), token: "test-token"))
        for token in ["", "a b", "a\n", "a\u{0}", "é", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try decode("https://example.invalid/v1/snapshot", token))
        }
        for base in ["https://example.invalid", "https://example.invalid/nested/prefix/", "https://example.invalid:8443/a%20b"] {
            let pairing = try Pairing(baseURL: base, token: String(repeating: "a", count: 128))
            let restored = try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(pairing))
            XCTAssertEqual(restored.endpoint, pairing.endpoint)
            XCTAssertEqual(restored.token, pairing.token)
        }
    }

    #if os(iOS)
    func testFailedReplacementNeverFallsBackToAddAndUsesDeviceOnlyProtection() throws {
        let pairing = try Pairing(baseURL: "https://example.invalid", token: "new-token")
        let data = try ConnectionRecord(generation: UUID(), mode: .bridge,
            credential: ConnectionStore.encoded(pairing)).encoded()
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecDuplicateItem] {
            XCTAssertThrowsError(try ConnectionKeychain.write(data, update: { _, attributes in
                let values = attributes as NSDictionary
                XCTAssertEqual(values[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                return status
            }, add: { _, _ in XCTFail("Must not replace/delete a usable item after update failure"); return errSecSuccess }))
        }
        XCTAssertThrowsError(try ConnectionKeychain.write(data, update: { _, _ in errSecItemNotFound }, add: { item, _ in
            XCTAssertEqual((item as NSDictionary)[kSecAttrAccessible] as? String,
                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            return errSecDuplicateItem
        }))
    }
    #endif
}

private final class BridgeProtocol: URLProtocol {
    static let cancellableStarted = Notification.Name("BridgeProtocol.cancellableStarted")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        XCTAssertFalse(path.contains("must-not-start"))
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertTrue(path.hasSuffix("/v1/snapshot"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        if path.contains("cancel-inflight") {
            NotificationCenter.default.post(name: Self.cancellableStarted, object: nil)
            return
        }
        if path.contains("silent-headers") { return }
        if path.contains("network") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let status = [401, 403, 302, 500].first { path.contains("/\($0)/") } ?? 200
        var headers = ["Set-Cookie": "private-cookie=secret; Secure", "Location": "https://other.invalid/never"]
        if path.contains("declared-oversize") { headers["Content-Length"] = "262145" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if path.contains("silent-body") { return }
        var data = Data("{\"schemaVersion\":1,\"generatedAt\":\"2026-10-13T10:00:00Z\",\"demo\":false,\"providers\":[]}".utf8)
        if path.contains("exact-cap") { data.append(Data(repeating: 32, count: 256 * 1024 - data.count)) }
        if path.contains("oversize") { data = Data(repeating: 32, count: 256 * 1024 + 1) }
        if path.contains("malformed") || status != 200 { data = Data("private response diagnostic".utf8) }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
