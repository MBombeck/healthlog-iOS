import Foundation
import Observation

/// **v0.9.0 RA3 (Option B) — unified per-medication delivery-preference
/// store.**
///
/// Owns the device-local override layer (UserDefaults) and merges it with
/// the injected server-default layer (`DeliveryDefaultsProviding`). The
/// single source for both the per-med Live-Activity opt-in (channel
/// `.liveActivity`, v0.9.0 — the standalone `LiveActivityPreferences` shim
/// was removed) and the new AlarmKit-critical opt-in.
///
/// **Resolution:** `effective(medicationId:channel:)` returns
/// `localOverride ?? serverDefault ?? channel.hardcodedDefault`. A present
/// local-override key = "this device overrides" (`scope == .thisDevice`);
/// an absent key = "follow the server / hardcoded default"
/// (`scope == .allDevices`).
///
/// **Server-default cache:** the async server layer is snapshotted into an
/// in-memory `serverDefaults` dict so the gating predicates
/// (`enabledPredicate(for:)`) stay **pure + synchronous** — exactly what the
/// `MedicationLiveActivityPlan` gate + the AlarmKit reconcile router need.
/// With the `NoServerDeliveryDefaults` stub the cache is always empty, so
/// resolution is purely local (today's behaviour).
///
/// **Migration:** the legacy `hl.liveActivity.enabled.<medId>` UserDefaults
/// values are migrated one-time into the unified
/// `hl.delivery.liveActivity.<medId>` keys (treated as `thisDevice`
/// overrides — the conservative read: an explicit local choice stays local
/// until the user re-picks "Alle Geräte").
///
/// Storage tier is **UserDefaults** for the overrides — UI-prefs the server
/// doesn't (yet) know, per the project's storage rules. Sensitive med
/// *intent* roams via the server-default layer once SB-LA-1 / SB-AK-1 ship.
@MainActor
@Observable
public final class DeliveryPreferencesStore {
    /// Unified local-override key prefix. A present key means the device
    /// overrides this `(medication × channel)`.
    static let keyPrefix = "hl.delivery."
    /// Local marker prefix recording the user's *intended* delivery scope
    /// for a `(medication × channel)`. Persisted separately from the value
    /// override so the scope picker remembers an "Alle Geräte" choice
    /// visually even while it degrades to a local value under the server
    /// stub (HIGH-6: the picker must not silently revert to "Dieses Gerät").
    static let scopeKeyPrefix = "hl.delivery.scope."
    /// Legacy Live-Activity key prefix migrated one-time into the unified
    /// scheme. Kept as a constant so the shim + the migration agree.
    static let legacyLiveActivityPrefix = "hl.liveActivity.enabled."
    /// One-time migration sentinel.
    private static let migrationDoneKey = "hl.delivery.migratedLA.v1"

    private let defaults: UserDefaults
    private let provider: DeliveryDefaultsProviding

    /// In-memory snapshot of the server-default layer, keyed by medication
    /// id. Empty with the stub; populated by `refreshServerDefaults(for:)`
    /// once the real provider lands. Read synchronously by the resolution +
    /// predicate paths so the gate stays pure.
    private var serverDefaults: [String: MedicationDeliveryDefaultsDTO] = [:]

    public init(
        defaults: UserDefaults = .standard,
        provider: DeliveryDefaultsProviding = NoServerDeliveryDefaults()
    ) {
        self.defaults = defaults
        self.provider = provider
        migrateLegacyLiveActivityIfNeeded()
    }

    // MARK: - Resolution

    /// The effective delivery pref for a `(medication × channel)` pair —
    /// `localOverride ?? serverDefault ?? hardcodedDefault`.
    public func effective(medicationId: String, channel: DeliveryChannel) -> DeliveryPreference {
        // The user's explicitly-remembered scope wins for display, so an
        // "Alle Geräte" pick that degraded to a local value under the server
        // stub still reads back as "Alle Geräte" (HIGH-6).
        let rememberedScope = intendedScope(medicationId: medicationId, channel: channel)
        if let local = localOverride(medicationId: medicationId, channel: channel) {
            return DeliveryPreference(enabled: local, scope: rememberedScope ?? .thisDevice)
        }
        if let server = serverDefaults[medicationId]?.value(for: channel) {
            return DeliveryPreference(enabled: server, scope: rememberedScope ?? .allDevices)
        }
        return DeliveryPreference(enabled: channel.hardcodedDefault, scope: rememberedScope ?? .allDevices)
    }

    /// Convenience — just the resolved enabled bool.
    public func isEnabled(medicationId: String, channel: DeliveryChannel) -> Bool {
        effective(medicationId: medicationId, channel: channel).enabled
    }

    // MARK: - Writes

    /// Persist the user's choice for a `(medication × channel)` at a scope.
    ///
    /// - `.thisDevice`: write the local override (always succeeds, stays on
    ///   this device).
    /// - `.allDevices`: clear the local override AND push the value to the
    ///   server-default layer so it roams. While the server field is
    ///   pending the provider throws `.unsupported`; we catch that, fall
    ///   back to writing a **local override** (so the user's choice still
    ///   takes effect on this device), and return `false` so the caller can
    ///   surface the non-blocking "Server-Sync folgt" hint.
    ///
    /// - Returns: `true` when the value was stored at the requested scope;
    ///   `false` when an "Alle Geräte" write degraded to local-only because
    ///   the server field is not available yet.
    @discardableResult
    public func set(
        enabled: Bool,
        scope: DeliveryScope,
        medicationId: String,
        channel: DeliveryChannel
    ) async -> Bool {
        // Remember the user's *intended* scope so the picker reads it back
        // verbatim on reopen, independent of how the value resolves (HIGH-6).
        setIntendedScope(scope, medicationId: medicationId, channel: channel)
        switch scope {
        case .thisDevice:
            setLocalOverride(enabled, medicationId: medicationId, channel: channel)
            return true
        case .allDevices:
            do {
                try await provider.setDefault(
                    medicationId: medicationId,
                    channel: channel,
                    enabled: enabled
                )
                // Server accepted the roaming default → drop the local
                // override so the device follows the user-level value, and
                // refresh the cache so the effective read reflects it.
                clearLocalOverride(medicationId: medicationId, channel: channel)
                await refreshServerDefaults(for: medicationId)
                return true
            } catch {
                // SERVER-PENDING SB-LA-1 / SB-AK-1 — the field doesn't exist
                // yet. Keep the user's choice effective on THIS device by
                // writing a local override; the UI shows the Server-Sync-
                // folgt hint instead of an error. The intended-scope marker
                // above still records "Alle Geräte" so the picker remembers it.
                setLocalOverride(enabled, medicationId: medicationId, channel: channel)
                return false
            }
        }
    }

    /// Synchronous local-only write — fire-and-forget device-local override
    /// without awaiting the server seam (used where a call site can't await,
    /// e.g. the Live-Activity opt-in path).
    public func setLocalOverride(_ enabled: Bool, medicationId: String, channel: DeliveryChannel) {
        defaults.set(enabled, forKey: key(medicationId: medicationId, channel: channel))
    }

    /// Remove a device-local override so the pair follows the server /
    /// hardcoded default again.
    public func clearLocalOverride(medicationId: String, channel: DeliveryChannel) {
        defaults.removeObject(forKey: key(medicationId: medicationId, channel: channel))
    }

    // MARK: - Server-default cache

    /// Refresh the in-memory server-default snapshot for a medication.
    ///
    /// **Dormant by design today.** The production provider is
    /// `NoServerDeliveryDefaults`, whose `defaults(...)` returns `nil` and
    /// whose `setDefault(...)` always throws `.unsupported` — so the only
    /// internal caller (the `.allDevices` success arm in `set`) never runs in
    /// production, and the `serverDefaults` cache stays empty (resolution is
    /// purely local). This is intentional forward-scaffolding for the
    /// SB-LA-1 / SB-AK-1 server fields; until a real `DeliveryDefaultsProviding`
    /// ships it is exercised only by the seam tests with an injected fake
    /// provider. The edit sheet does NOT call this on appear.
    public func refreshServerDefaults(for medicationId: String) async {
        if let dto = await provider.defaults(medicationId: medicationId) {
            serverDefaults[medicationId] = dto
        } else {
            serverDefaults.removeValue(forKey: medicationId)
        }
    }

    /// **v0.10 W-Meds-A2 (v1.7.0 SB-LA-1 / SB-AK-1) — ingest the per-medication
    /// delivery booleans that now arrive ON the medication contract itself.**
    ///
    /// The GET `/api/medications` rows carry `liveActivityEnabled` /
    /// `criticalAlarmEnabled` directly (when the server is v1.7.0-capable), so
    /// they ARE the user-level (roaming) default in the resolution chain
    /// `localOverride ?? serverDefault ?? hardcodedDefault`. Folding them into
    /// `serverDefaults` makes the existing gating predicates respect them with
    /// no scheduler-side change — a Live Activity / critical alarm only arms
    /// when the resolved value is true.
    ///
    /// Synchronous + medication-driven (unlike `refreshServerDefaults`, which is
    /// the dormant `DeliveryDefaultsProviding` seam). Only ingests a row when at
    /// least one boolean is non-nil — against the CURRENT server (both nil) the
    /// cache stays empty for that med and resolution falls through to the local
    /// override / hardcoded default exactly as before (no behaviour flip).
    public func ingestServerDefaults(from medications: [Medication]) {
        for medication in medications {
            let live = medication.liveActivityEnabled
            let critical = medication.criticalAlarmEnabled
            guard live != nil || critical != nil else { continue }
            serverDefaults[medication.id] = MedicationDeliveryDefaultsDTO(
                medicationId: medication.id,
                liveActivityEnabled: live,
                criticalAlarmEnabled: critical
            )
        }
    }

    // MARK: - Predicate snapshots

    /// A pure, `Sendable` predicate snapshot keyed by medication id for one
    /// channel — handed to the `MedicationLiveActivityPlan` gate + the
    /// AlarmKit reconcile router so the gating decision stays a pure,
    /// unit-testable function with no store coupling.
    ///
    /// Snapshots the local overrides (from UserDefaults) + the cached server
    /// defaults into plain value types so the returned closure captures no
    /// reference type.
    public func enabledPredicate(for channel: DeliveryChannel) -> @Sendable (String) -> Bool {
        let prefix = key(prefixFor: channel)
        let fallback = channel.hardcodedDefault
        let localSnapshot: [String: Bool] = defaults.dictionaryRepresentation()
            .reduce(into: [:]) { result, entry in
                guard entry.key.hasPrefix(prefix), let value = entry.value as? Bool else { return }
                let id = String(entry.key.dropFirst(prefix.count))
                result[id] = value
            }
        let serverSnapshot: [String: Bool] = serverDefaults.reduce(into: [:]) { result, entry in
            if let value = entry.value.value(for: channel) { result[entry.key] = value }
        }
        return { medicationId in
            localSnapshot[medicationId] ?? serverSnapshot[medicationId] ?? fallback
        }
    }

    // MARK: - Logout

    /// v0.14.8 W3 (AUDIT-SECURITY-B175 M-1/M-3) — wipe the per-medication
    /// override layer on logout. The keys are previous-user-scoped garbage for
    /// the next account AND reveal *that* certain medication entities existed
    /// on the device. Prefix-keyed sweep over `hl.delivery.*` (value + scope
    /// keys; the one-time migration sentinel goes with them — re-running the
    /// migration against the also-wiped legacy keys is a no-op) plus the
    /// legacy `hl.liveActivity.enabled.*` keys, then the in-memory
    /// server-default snapshot.
    public func clearOnLogout() {
        for storedKey in defaults.dictionaryRepresentation().keys
            where storedKey.hasPrefix(Self.keyPrefix) || storedKey.hasPrefix(Self.legacyLiveActivityPrefix)
        {
            defaults.removeObject(forKey: storedKey)
        }
        serverDefaults = [:]
    }

    // MARK: - Internals

    private func localOverride(medicationId: String, channel: DeliveryChannel) -> Bool? {
        defaults.object(forKey: key(medicationId: medicationId, channel: channel)) as? Bool
    }

    /// Persist the user's intended delivery scope as a separate local marker.
    private func setIntendedScope(_ scope: DeliveryScope, medicationId: String, channel: DeliveryChannel) {
        defaults.set(scope.rawValue, forKey: scopeKey(medicationId: medicationId, channel: channel))
    }

    /// The user's previously-chosen scope for this pair, if any.
    private func intendedScope(medicationId: String, channel: DeliveryChannel) -> DeliveryScope? {
        guard let raw = defaults.string(forKey: scopeKey(medicationId: medicationId, channel: channel)) else {
            return nil
        }
        return DeliveryScope(rawValue: raw)
    }

    private func scopeKey(medicationId: String, channel: DeliveryChannel) -> String {
        "\(Self.scopeKeyPrefix)\(channel.rawValue).\(medicationId)"
    }

    private func key(medicationId: String, channel: DeliveryChannel) -> String {
        key(prefixFor: channel) + medicationId
    }

    private func key(prefixFor channel: DeliveryChannel) -> String {
        "\(Self.keyPrefix)\(channel.rawValue)."
    }

    /// One-time migration of the legacy `hl.liveActivity.enabled.<medId>`
    /// keys into the unified `hl.delivery.liveActivity.<medId>` scheme.
    /// Existing explicit local choices migrate as `thisDevice` overrides.
    /// Idempotent via the `migrationDoneKey` sentinel.
    private func migrateLegacyLiveActivityIfNeeded() {
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return }
        let legacyPrefix = Self.legacyLiveActivityPrefix
        for (storedKey, value) in defaults.dictionaryRepresentation()
            where storedKey.hasPrefix(legacyPrefix)
        {
            guard let boolValue = value as? Bool else { continue }
            let medicationId = String(storedKey.dropFirst(legacyPrefix.count))
            let newKey = key(medicationId: medicationId, channel: .liveActivity)
            // Don't clobber a value already written under the unified key.
            if defaults.object(forKey: newKey) == nil {
                defaults.set(boolValue, forKey: newKey)
            }
        }
        defaults.set(true, forKey: Self.migrationDoneKey)
    }
}
