import Foundation

/// **v0.9.0 RA3 — server seam for per-medication delivery defaults.**
///
/// The user-level (roaming) layer of the `DeliveryPreferences` resolution
/// chain. Today the **only** conformer is `NoServerDeliveryDefaults`, which
/// returns `nil` for every lookup and throws `.unsupported` on write — so
/// the effective value falls back to the device-local override and the app
/// behaves exactly as it did before v0.9.0.
///
/// When the server lands the SB-LA-1 (`liveActivityEnabled`) + SB-AK-1
/// (`criticalAlarmEnabled`) fields on the medication contract, a real
/// conformer wraps `GET /api/medications` (echo) + `PUT
/// /api/medications/[id]` (write) and the `DeliveryPreferencesStore` swaps
/// the stub for it — **no View / call-site change**. See
/// `RA3-settings-sync-plan.md` §7.
///
/// `Sendable` so the store can hold it across actor hops; the live
/// implementation will be an `actor` wrapping the repo.
public protocol DeliveryDefaultsProviding: Sendable {
    /// The user-level defaults for a medication, or `nil` when the server
    /// carries no value (or the field doesn't exist yet — the stub case).
    func defaults(medicationId: String) async -> MedicationDeliveryDefaultsDTO?

    /// Persist a user-level default for one channel. Throws
    /// `DeliveryDefaultsError.unsupported` while the server field is
    /// pending (the stub), which the store treats as a non-blocking
    /// "stays local for now" outcome.
    func setDefault(
        medicationId: String,
        channel: DeliveryChannel,
        enabled: Bool
    ) async throws
}

/// Error surface for the delivery-defaults seam.
public enum DeliveryDefaultsError: Error, Sendable, Equatable {
    /// The server field does not exist yet (SB-LA-1 / SB-AK-1 pending).
    /// The store catches this and keeps the value device-local, surfacing
    /// the non-blocking "Server-Sync folgt" hint instead of an error.
    case unsupported
}

/// **The current (v0.9.0) server seam — a no-op stub.**
///
/// Returns `nil` for every default lookup → the `DeliveryPreferencesStore`
/// resolution falls through to the local override / hardcoded default, i.e.
/// today's purely-device-local behaviour. `setDefault` throws
/// `.unsupported`, which the store interprets as "keep it local + show the
/// Server-Sync-folgt hint", never surfacing a user-visible failure.
///
/// SERVER-PENDING SB-LA-1 / SB-AK-1 — swap this for the live repo-backed
/// conformer once the medication contract carries `liveActivityEnabled` +
/// `criticalAlarmEnabled`. Until then this is the production conformer and
/// the architecture ships safely without any server work.
public struct NoServerDeliveryDefaults: DeliveryDefaultsProviding {
    public init() {}

    public func defaults(medicationId _: String) async -> MedicationDeliveryDefaultsDTO? {
        // SERVER-PENDING SB-LA-1 / SB-AK-1 — no server field yet.
        nil
    }

    public func setDefault(
        medicationId _: String,
        channel _: DeliveryChannel,
        enabled _: Bool
    ) async throws {
        // SERVER-PENDING SB-LA-1 / SB-AK-1 — the "Alle Geräte" scope cannot
        // roam until the server field exists; signal the store to keep the
        // value device-local + surface the non-blocking hint.
        throw DeliveryDefaultsError.unsupported
    }
}
