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
    /// Audit B-7 — the mirror's `UserDefaults` key, app-scoped. #115 B5: the
    /// widget extension reads the account-scoped App-Group copy instead
    /// (``SharedAccountPrefs``), because this domain is invisible to it.
    static let defaultsKey = "hl.profile.timeZoneIdentifier"

    /// #115 1.5 — the app-wide box. `AppContainer` feeds THIS instance from the
    /// settings store, so every day key the app cuts (``ProfileDay``) reads the
    /// same zone the medication / dashboard / measurement keys already use,
    /// including from a view or a repository that holds no container.
    ///
    /// #115 B5 — it also mirrors into the account-scoped App-Group entry
    /// (``SharedAccountPrefs/live``), so the widget extension, whose
    /// `.standard` domain never saw the app's mirror, cuts the same days.
    public static let shared = ProfileTimeZoneBox(sharedPrefs: .live)

    /// `nil` until a zone was pushed or the seed was read — see ``current``.
    private let storage: OSAllocatedUnfairLock<TimeZone?>
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` in the
    /// Swift 6 sense while being documented as thread-safe. The box is read from
    /// off-main-actor `@Sendable` providers, which is the whole point of it.
    private nonisolated(unsafe) let defaults: UserDefaults
    /// #115 B5 — the account-scoped App-Group mirror, or `nil` (tests).
    private let sharedPrefs: SharedAccountPrefs?

    /// - Parameters:
    ///   - defaults: where the last resolved identifier is mirrored.
    ///     Injectable so a test can seed one without touching the process store.
    ///   - sharedPrefs: #115 B5 — the App-Group mirror an extension reads.
    public init(defaults: UserDefaults = .standard, sharedPrefs: SharedAccountPrefs? = nil) {
        self.defaults = defaults
        self.sharedPrefs = sharedPrefs
        storage = OSAllocatedUnfairLock<TimeZone?>(initialState: nil)
    }

    /// #115 B5 — the seed, in order: the account-scoped App-Group entry for
    /// the account signed in now, the app's own mirror, the device zone. Read
    /// once, on first use rather than at construction, so the Keychain lookup
    /// behind the account check never runs on a path that never asks.
    private func seed() -> TimeZone {
        if let zone = sharedPrefs?.timeZone() { return zone }
        return Self.seedZone(identifier: defaults.string(forKey: Self.defaultsKey))
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
        if let zone = storage.withLock({ $0 }) { return zone }
        // The seed reads UserDefaults and the Keychain — outside the unfair
        // lock. A push that lands meanwhile wins over the seed.
        let seeded = seed()
        return storage.withLock { state in
            if let zone = state { return zone }
            state = seeded
            return seeded
        }
    }

    /// Push the latest resolved zone. Called on the main actor whenever the
    /// profile timezone could change.
    ///
    /// Audit B-7 — also mirrors the identifier so the NEXT launch (including a
    /// background wake that never loads a profile) starts on it.
    public func update(_ timeZone: TimeZone) {
        storage.withLock { $0 = timeZone }
        defaults.set(timeZone.identifier, forKey: Self.defaultsKey)
        sharedPrefs?.setTimeZone(timeZone)
    }

    /// **#115 B5 — the update path into the App-Group mirror.** An install that
    /// resolved its account zone before this build has it only in the app's own
    /// mirror; the extension would keep answering the device zone until the next
    /// `/me` emission. Copy it across once, when the shared entry for the
    /// signed-in account is still empty. Never overwrites a shared entry.
    public func mirrorIntoSharedIfUnset() {
        guard let sharedPrefs, sharedPrefs.timeZone() == nil,
              let identifier = defaults.string(forKey: Self.defaultsKey),
              let zone = TimeZone(identifier: identifier) else { return }
        sharedPrefs.setTimeZone(zone)
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
