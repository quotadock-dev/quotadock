import Foundation
import WatchConnectivity
import WidgetKit

final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()
    // Access only on the main queue, alongside the phone's cache mutations.
    private var transfer = WatchTransfer()
    private override init() { super.init() }
    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func send() {
        #if os(iOS)
        guard WCSession.isSupported() else { return }
        onMain {
            // Never relabel a captured pre-switch snapshot as current state.
            self.transfer.reconcile(phoneSnapshot: SnapshotStore.load())
            self.flush(WCSession.default)
        }
        #endif
    }
    func syncLanguage() {
        #if os(iOS)
        guard WCSession.isSupported() else { return }
        onMain {
            // A language change must never export the in-memory demo screen.
            self.transfer.reconcile(phoneSnapshot: SnapshotStore.load())
            self.flush(WCSession.default)
        }
        #endif
    }
    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
    private func flush(_ session: WCSession) {
        guard session.activationState == .activated, let data = transfer.pending else { return }
        do {
            var context: [String: Any] = ["snapshot": data,
                                         DockL10n.languageKey: DockL10n.selection().rawValue]
            #if os(iOS)
            guard let group = SnapshotStore.groupURL else { return }
            let publisher = AccountSurfacePublisher(stateURL: group.appendingPathComponent("account-surface-publisher"))
            // Only an explicitly selected bridge may publish UUID-less legacy
            // authority. Missing/failed cloud cache must never become first-slot fallback.
            let bridge = (try? ConnectionStore.current().mode) == .bridge
            context["accountSurfaceV3"] = try publisher.next(snapshot: bridge ? nil : SnapshotStore.loadAccounts(),
                legacy: bridge ? SnapshotStore.load() : nil)
            // Bound the combined context as well as each versioned payload.
            // If parallel v1 compatibility makes it too large, send an explicit
            // sequenced unavailability rather than silently truncating UUIDs.
            if try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0).count > SnapshotStore.maximumPayloadBytes {
                context["accountSurfaceV3"] = try publisher.next(snapshot: nil)
            }
            #endif
            guard try PropertyListSerialization.data(fromPropertyList: context, format: .binary, options: 0).count <= SnapshotStore.maximumPayloadBytes else { return }
            try session.updateApplicationContext(context)
            transfer.accepted()
        } catch {
            // Keep the latest intention for a later send/activation; acceptance
            // by WCSession still does not promise immediate OS delivery.
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        #if os(iOS)
        guard activationState == .activated, error == nil else { return }
        onMain {
            // This is authoritative companion-phone state, never Watch-local
            // absence. Reconcile even after restart, when no outbox survives.
            self.transfer.reconcile(phoneSnapshot: SnapshotStore.load())
            self.flush(session)
        }
        #endif
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        #if os(watchOS)
        // Serialize disk fences and UI updates; a delayed legacy context must
        // never replace an accepted UUID-aware authority.
        onMain { self.receive(applicationContext) }
        #endif
    }
    #if os(watchOS)
    func trustCurrentCompanion() {
        guard Thread.isMainThread, let inbox = SnapshotStore.accountInbox,
              let data = WCSession.default.receivedApplicationContext["accountSurfaceV3"] as? Data else { return }
        do { try inbox.trustPairedPublisher(data) } catch { /* Remain fenced on failed persistence. */ }
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
    }
    private func receive(_ applicationContext: [String: Any]) {
        if let data = applicationContext["accountSurfaceV3"] as? Data {
            guard let inbox = SnapshotStore.accountInbox else { return }
            do { try inbox.receive(data) } catch {
                WidgetCenter.shared.reloadAllTimelines()
                NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
                return
            }
            // New Watch uses only sequence-fenced authority after this point.
            // UUID-less quota is allowed only by an explicit bridge envelope.
            applyLanguage(applicationContext)
            WidgetCenter.shared.reloadAllTimelines()
            NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
            return
        }
        guard SnapshotStore.accountInbox?.hasAuthority != true else { return }
        guard let data = applicationContext["snapshot"] as? Data,
              data.count <= SnapshotStore.maximumPayloadBytes,
              let snapshot = try? Snapshot.decode(data) else { return }
        // WCSession callbacks are not main-thread callbacks. Do not announce a
        // new cache (or reload widgets) if persistence failed, e.g. before unlock.
        do { try SnapshotStore.replaceFromCompanion(snapshot) } catch { return }
        applyLanguage(applicationContext)
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadAllTimelines()
            NotificationCenter.default.post(name: .snapshotUpdated, object: nil)
        }
    }
    private func applyLanguage(_ context: [String: Any]) {
        if let raw = context[DockL10n.languageKey] as? String, let language = DockLanguage(rawValue: raw) {
            DockL10n.save(language)
        }
    }
    #endif
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}

extension Notification.Name { static let snapshotUpdated = Notification.Name("snapshotUpdated") }
