import Foundation
import os

/// Thread-safe, `Sendable` snapshot of the user's resolved server-profile
/// timezone (AUD-3 D-3).
///
/// **Why this exists:** the `@MainActor` stores (`MedicationsStore` /
/// `DashboardStore`) read the profile timezone live off `settingsStore.profile`
/// in a `() -> TimeZone` provider — safe because they share the store's main-
/// actor isolation. `MeasurementsRepository` is an `actor` running OFF the main
/// actor, so its day-anchoring provider must be `@Sendable`; it cannot reach
/// into the `@MainActor` `SettingsStore` without a data race. This box is the
/// race-free bridge: the main actor PUSHES the resolved zone on every profile
/// change (`SettingsStore.profile.didSet`), and the repo's `@Sendable` provider
/// READS the latest snapshot under a lock.
///
/// **Audit B-7 — it also remembers, because a background wake has nobody to
/// push it.** The push only happens once the UI has loaded a profile. A
/// HealthKit background delivery (`AppOwnedHealthCollection.install`) runs a
/// whole sync pass without that: the app was launched into the background, no
/// screen mounted, no `/api/user/profile` fetched. Seeded from `.current`, a
/// travelling user's day rows were cut in the DEVICE zone on exactly that path
/// — the one place the fix in `MeasurementsRepository` could not reach. So the
/// last resolved identifier is mirrored into `UserDefaults` on every update and
/// read back at construction. It is a CACHE of the server's answer, not a
/// second source of truth: the first real profile emission overwrites it, and
/// an absent or unparseable identifier falls back to `.current` exactly as
/// before.
public final class ProfileTimeZoneBox: Sendable {
    /// Audit B-7 — the mirror's `UserDefaults` key. App-scoped (not the app
    /// group): every consumer of the box lives in the main app process.
    static let defaultsKey = "hl.profile.timeZoneIdentifier"

    private let storage: OSAllocatedUnfairLock<TimeZone>
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` in the
    /// Swift 6 sense while being documented as thread-safe. The box is read from
    /// off-main-actor `@Sendable` providers, which is the whole point of it.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// - Parameter defaults: where the last resolved identifier is mirrored.
    ///   Injectable so a test can seed one without touching the process store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storage = OSAllocatedUnfairLock<TimeZone>(
            initialState: Self.seedZone(identifier: defaults.string(forKey: Self.defaultsKey))
        )
    }

    /// Audit B-7 — the pure seeding rule: a stored IANA identifier this device
    /// can resolve wins; anything else (absent, empty, renamed out of the
    /// system database) falls back to the device zone.
    ///
    /// Pure and `static` so the fallback can be asserted without a container.
    public static func seedZone(identifier: String?) -> TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return .current }
        return zone
    }

    /// Latest resolved server-profile timezone (the mirrored one until the
    /// first profile emission of this launch, `.current` when there is none).
    public var current: TimeZone {
        storage.withLock { $0 }
    }

    /// Push the latest resolved zone. Called on the main actor whenever the
    /// profile timezone could change.
    ///
    /// Audit B-7 — also mirrors the identifier so the NEXT launch (including a
    /// background wake that never loads a profile) starts on it.
    public func update(_ timeZone: TimeZone) {
        storage.withLock { $0 = timeZone }
        defaults.set(timeZone.identifier, forKey: Self.defaultsKey)
    }

    /// **Audit B-7 (fix round 1) — push a zone only when the profile has
    /// actually stated one.**
    ///
    /// The composition root seeds this box from inside `AppContainer.init`, and
    /// at that moment `SettingsStore.profile` is still `nil` — it is hydrated
    /// only by the async SWR load. `resolvedProfileTimeZone` therefore answers
    /// `.current`, and pushing that answer through ``update(_:)`` replaced BOTH
    /// the seeded zone and the `UserDefaults` mirror with the DEVICE zone on
    /// every single launch — including the background wake the mirror exists
    /// for, which then cut its day rows in the device zone and destroyed the
    /// mirror the next wake would have read.
    ///
    /// A `nil` or unresolvable identifier is not a statement about the user's
    /// zone; it is the absence of one. The seed stands, and the first real
    /// profile emission (`SettingsStore.profile.didSet`, which IS a server
    /// statement) still overwrites it through ``update(_:)``.
    public func updateIfResolved(_ identifier: String?) {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return }
        update(zone)
    }
}
