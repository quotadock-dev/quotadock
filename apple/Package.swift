// swift-tools-version: 5.9
import PackageDescription

// Executes the same Foundation storage/bridge code on Linux/macOS without emulating
// Keychain, UIKit, WidgetKit or WatchConnectivity.
let package = Package(
    name: "QuotaDockStorage",
    products: [.library(name: "QuotaDockStorage", targets: ["QuotaDockStorage"])],
    targets: [
        .target(name: "QuotaDockStorage", path: ".", exclude: [
            "Assets.xcassets", "Resources", "Tests", "UITests", "Watch", "Widgets",
            "PortableTests", "Preview", "README.md", "BILLING.md", "project.yml", "project-preview.yml", "verify-persistence.py",
            "iOS/ConnectionStore.swift",
            "iOS/Cloud.swift", "iOS/FirstRun.swift", "iOS/Purchases.swift",
            "iOS/PlanViews.swift", "iOS/CloudAccountsView.swift", "iOS/CloudAccountSurfaces.swift",
            "iOS/CloudHistoryView.swift", "iOS/CloudHistoryDetails.swift",
            "iOS/QuotaAccessibilityPreview.swift", "iOS/QuotaDockApp.swift",
            "iOS/WatchSurfacePreview.swift", "iOS/WidgetSurfacePreview.swift",
            "Shared/Localization.swift", "Shared/ProviderIcon.swift",
            "Shared/QuotaViews.swift", "Shared/SnapshotStore.swift", "Shared/WatchContent.swift",
            "Shared/WatchSync.swift", "Shared/WidgetContent.swift"
        ], sources: ["Shared/Snapshot.swift", "Shared/QuotaAlerts.swift", "Shared/CacheFiles.swift", "Shared/Bridge.swift",
                     "Shared/AccountSurface.swift", "Shared/WatchTransfer.swift", "iOS/BillingPolicy.swift",
                     "iOS/ConnectionState.swift", "iOS/CloudAccountLabels.swift", "iOS/QuotaHistory.swift"]),
        .testTarget(name: "QuotaDockStorageTests", dependencies: ["QuotaDockStorage"], path: "PortableTests")
    ]
)
