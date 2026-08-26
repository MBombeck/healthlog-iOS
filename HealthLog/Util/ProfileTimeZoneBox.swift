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
/// Defaults to `.current` so the pre-hydration window + unit tests stay
/// byte-unchanged with the previous `MedicationDayKey.string(timeZone: .current)`
/// behaviour.
public final class ProfileTimeZoneBox: Sendable {
    private let storage = OSAllocatedUnfairLock<TimeZone>(initialState: .current)

    public init() {}

    /// Latest resolved server-profile timezone (or `.current` until hydrated).
    public var current: TimeZone {
        storage.withLock { $0 }
    }

    /// Push the latest resolved zone. Called on the main actor whenever the
    /// profile timezone could change.
    public func update(_ timeZone: TimeZone) {
        storage.withLock { $0 = timeZone }
    }
}
