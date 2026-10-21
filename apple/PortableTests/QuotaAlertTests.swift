import Foundation
import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class QuotaAlertTests: XCTestCase {
    private let key = "inAppQuotaAlerts.v1"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func isolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "QuotaAlertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func window(_ id: String, _ value: Double?, reset: Date? = nil) -> QuotaWindow {
        QuotaWindow(id: id, label: id == "primary" ? "Session" : "Weekly",
                    remainingPercent: value, resetsAt: reset)
    }

    private func provider(_ windows: [QuotaWindow],
                          observedAt: Date? = Date(timeIntervalSince1970: 1_699_999_940),
                          state: ProviderState = .available, source: QuotaSource = .codexbar) -> Provider {
        Provider(id: .claude, name: "Claude", plan: nil, state: state, source: source,
                 message: nil, observedAt: observedAt, windows: windows)
    }

    func testPreferenceIsOptInAndValidSavesRoundTripAsJSONData() throws {
        XCTAssertEqual(QuotaAlerts.thresholds, [10, 20, 30])
        try isolatedDefaults { defaults in
            XCTAssertNil(QuotaAlerts.threshold(in: defaults))
            for threshold in [10, 20, 30] {
                XCTAssertTrue(QuotaAlerts.save(threshold: threshold, in: defaults))
                let stored = try XCTUnwrap(defaults.object(forKey: key) as? Data)
                XCTAssertEqual(try JSONDecoder().decode(Int.self, from: stored), threshold)
                XCTAssertEqual(QuotaAlerts.threshold(in: defaults), threshold)
            }
            XCTAssertTrue(QuotaAlerts.save(threshold: nil, in: defaults))
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertNil(QuotaAlerts.threshold(in: defaults))
        }
    }

    func testMalformedAndNonDataPreferencesAreOffAndInvalidSavesDoNotMutate() throws {
        try isolatedDefaults { defaults in
            let invalid: [Any] = [10, true, "20", [20],
                                  Data(), Data("not json".utf8), Data("true".utf8),
                                  Data("false".utf8), Data("null".utf8), Data("\"20\"".utf8),
                                  Data("[20]".utf8), Data("{}".utf8), Data("20.5".utf8),
                                  Data("0".utf8), Data("19".utf8), Data("31".utf8)]
            for value in invalid {
                defaults.set(value, forKey: key)
                XCTAssertNil(QuotaAlerts.threshold(in: defaults), "\(value)")
            }
            defaults.removeObject(forKey: key)
            for value in [-1, 0, 9, 11, 19, 21, 29, 31, 100] {
                XCTAssertFalse(QuotaAlerts.save(threshold: value, in: defaults))
                XCTAssertNil(defaults.object(forKey: key))
            }
            XCTAssertTrue(QuotaAlerts.save(threshold: 20, in: defaults))
            let original = try XCTUnwrap(defaults.data(forKey: key))
            for value in [-1, 0, 11, 21, 31, 100] {
                XCTAssertFalse(QuotaAlerts.save(threshold: value, in: defaults))
                XCTAssertEqual(defaults.data(forKey: key), original)
                XCTAssertEqual(QuotaAlerts.threshold(in: defaults), 20)
            }
        }
    }

    func testOnlyFreshAvailableCodexbarObservationsQualify() {
        let low = window("primary", 3)
        for (epoch, eligible) in [(1_700_000_000.0, true), (1_699_999_999.9, true),
                                  (1_699_999_100.1, true), (1_699_999_100.0, true),
                                  (1_699_999_099.9, false), (1_700_000_000.1, false)] {
            let reading = provider([low], observedAt: Date(timeIntervalSince1970: epoch))
            XCTAssertEqual(QuotaAlerts.lowWindows(in: reading, threshold: 10, now: now),
                           eligible ? [low] : [], "observed epoch \(epoch)")
        }
        XCTAssertTrue(QuotaAlerts.lowWindows(in: provider([low], observedAt: nil), threshold: 10, now: now).isEmpty)
        for state in [ProviderState.available, .unavailable, .error] {
            for source in [QuotaSource.codexbar, .demo] {
                let reading = provider([low], state: state, source: source)
                XCTAssertEqual(QuotaAlerts.lowWindows(in: reading, threshold: 10, now: now),
                               state == .available && source == .codexbar ? [low] : [])
            }
        }
        for threshold: Int? in [nil, -1, 0, 9, 11, 19, 21, 29, 31, 100] {
            XCTAssertTrue(QuotaAlerts.lowWindows(in: provider([low]), threshold: threshold, now: now).isEmpty)
        }
    }

    func testEachThresholdFiltersWindowsIndependentlyAndInclusively() {
        for threshold in [10, 20, 30] {
            let below = window("secondary", Double(threshold) - 0.1)
            let equal = window("primary", Double(threshold))
            let above = window("tertiary", Double(threshold) + 0.1)
            for windows in [[above, below, equal], [equal, above, below]] {
                XCTAssertEqual(QuotaAlerts.lowWindows(in: provider(windows), threshold: threshold, now: now),
                               windows.filter { $0.id != "tertiary" })
            }
        }
    }

    func testUnknownNonFiniteAndOutOfRangeAreNotClampedIntoLowValues() {
        let zero = window("primary", 0)
        for value: Double? in [nil, .nan, .infinity, -.infinity, -0.1, 100.1, 100] {
            let other = window("secondary", value)
            XCTAssertEqual(QuotaAlerts.lowWindows(in: provider([other, zero]), threshold: 30, now: now), [zero])
        }
        XCTAssertTrue(QuotaAlerts.lowWindows(in: provider([]), threshold: 30, now: now).isEmpty)
    }

    func testResetsAndSnapshotGenerationDoNotReplaceObservedMeasurements() {
        let passed = window("secondary", 7, reset: Date(timeIntervalSince1970: 1_699_999_990))
        let future = window("primary", 2, reset: Date(timeIntervalSince1970: 1_700_003_600))
        let unknown = window("tertiary", nil, reset: Date(timeIntervalSince1970: 1_699_999_000))
        let reading = provider([passed, unknown, future])
        for epoch in [1_600_000_000.0, 1_800_000_000.0] {
            let snapshot = Snapshot(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: epoch),
                                    demo: false, providers: [reading])
            XCTAssertEqual(QuotaAlerts.lowWindows(in: snapshot.providers[0], threshold: 10, now: now),
                           [passed, future])
        }
        let later = Date(timeIntervalSince1970: 1_700_000_010)
        XCTAssertEqual(QuotaAlerts.lowWindows(in: reading, threshold: 10, now: later), [passed, future])
    }
}
