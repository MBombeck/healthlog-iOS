import Foundation
import Observation

/// `@Observable` store for the LOCAL feature flags (HealthKit ingest switches,
/// cycle-tracking default).
///
/// **#114 / #115 · 0.2 — no server read any more.** This store used to fetch
/// `GET /api/feature-flags` and carry four assistant keys. The fetch never
/// worked (the app decoded an invented `{ flags }` shape; the server sends
/// `{ assistant }`), so every assistant key always sat at its default "on",
/// and the route is deprecated server-side. AI availability now comes from
/// `GET /api/auth/me` `ai` through ``AICapabilityGate``. What is left here is a
/// pure local map with the flags' own defaults; nothing a previous build cached
/// can gate an AI surface through it.
///
/// `@MainActor` because SwiftUI reads it during `body` evaluation; the HealthKit
/// coordinators read the same state through ``liveService()`` without a hop.
@MainActor
@Observable
public final class FeatureFlagsStore {
    /// Local overrides. Empty in production: every flag reads its
    /// ``FeatureFlag/defaultValue``.
    public private(set) var flags: [FeatureFlag: Bool] = [:]

    /// Sendable shadow cell that mirrors ``flags`` so cross-actor readers can
    /// sync-query the map without a MainActor hop.
    private let liveCell = LiveFlagsCell()

    public init() {}

    /// Live `FeatureFlagsServicing` adaptor backed by the shadow cell.
    public func liveService() -> LiveFeatureFlagsService {
        let cell = liveCell
        return LiveFeatureFlagsService(resolve: { flag in
            cell.isEnabled(flag)
        })
    }

    /// Synchronous flag query.
    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        flags[flag] ?? flag.defaultValue
    }

    /// Sendable view of the current flag map.
    public var snapshot: FeatureFlagsStoreSnapshot {
        FeatureFlagsStoreSnapshot(flags: flags)
    }

    /// Local override (tests, debug builds).
    public func setOverride(_ flag: FeatureFlag, enabled: Bool?) {
        flags[flag] = enabled
        liveCell.store(flags)
    }

    /// Wipes overrides on logout.
    public func clearOnLogout() {
        flags = [:]
        liveCell.store(flags)
    }
}

/// Sendable lock-guarded shadow of the flag map. Reads cross actor isolation;
/// writes happen on the MainActor from `FeatureFlagsStore`.
final class LiveFlagsCell: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: [FeatureFlag: Bool] = [:]

    func store(_ next: [FeatureFlag: Bool]) {
        lock.withLock { flags = next }
    }

    func isEnabled(_ flag: FeatureFlag) -> Bool {
        lock.withLock { flags[flag] ?? flag.defaultValue }
    }
}
