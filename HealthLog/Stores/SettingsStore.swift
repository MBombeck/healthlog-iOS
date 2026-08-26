import Foundation
import Observation
import SwiftUI

/// **SWR adoption (PA5 Bottleneck #2, v0.5.x):** the Settings tab used to
/// fire two fresh network requests on every mount (`/api/user/profile`
/// + `/api/user/hk-config`) with zero cache-paint capability. The
/// CacheKeys (`.userProfile`, `.hkSyncConfig`, both `staleAfter: 5 * 60`)
/// already existed; this store now consults `SWRCoordinator.observe`
/// for each surface in parallel.
///
/// Falls back to the direct-fetch path when `swr` is `nil` (unit tests
/// construct the store without a coordinator). Preserves the single-emit
/// post-load semantics existing `SettingsStoreProfileTests` rely on.
@MainActor
@Observable
public final class SettingsStore {
    /// `internal(set)` (not `private(set)`) so the Build 9
    /// `SettingsStore+ServerPrefs` extension — split into its own file for length
    /// — can splice the avatar. Still module-scoped; no external writes.
    public internal(set) var profile: UserProfile? {
        didSet {
            mirrorTimeFormatPreference()
            mirrorDateFormatPreference()
            // AUD-3 D-3 — push the resolved server-profile timezone to any
            // observer (e.g. the `MeasurementsRepository` day-anchoring box) so
            // off-main-actor consumers track profile-TZ changes race-free.
            onProfileTimeZoneChange?(resolvedProfileTimeZone)
        }
    }

    /// **AUD-3 D-3** — fired (on the main actor) whenever the profile timezone
    /// could change, with the freshly resolved zone. The composition root wires
    /// this to push into the `MeasurementsRepository` profile-TZ box so its
    /// `.dashboardSummary` invalidation day-key matches what `DashboardStore`
    /// reads. `@Sendable` so it can hand the value off to an actor.
    public var onProfileTimeZoneChange: (@Sendable (TimeZone) -> Void)?

    /// The server-profile IANA timezone resolved to a `TimeZone`, or `.current`
    /// when the profile carries no (valid) zone.
    public var resolvedProfileTimeZone: TimeZone {
        guard let raw = profile?.timezone, let zone = TimeZone(identifier: raw) else { return .current }
        return zone
    }

    public private(set) var hkConfig: HealthKitSyncConfig?
    public private(set) var isLoading: Bool = false
    public internal(set) var error: HLError?
    /// Set when either of the two visible payloads was served from cache
    /// (SWR `.cached` arm). Drives a future "showing cached" affordance
    /// on the Settings header — not surfaced yet but stays consistent
    /// with the other SWR-backed stores.
    public private(set) var isShowingStaleCache: Bool = false

    public var biometricLockEnabled: Bool {
        didSet { defaults.set(biometricLockEnabled, forKey: Keys.biometric) }
    }

    public var dashboardLayout: DashboardLayout {
        didSet { defaults.set(dashboardLayout.rawValue, forKey: Keys.dashLayout) }
    }

    public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Display-unit prefs (v0.4.1 / M2-A6). Persisted locally only — server-
    /// side cross-device sync is the v0.4.2 follow-up. UserDefaults usage is
    /// inside the "UI-prefs" allowlist per PROJECT_GUIDE.md (no Health-data, no
    /// tokens — purely display).
    /// **Build 9 (Server-Prefs) / 9.1 — Decision A.** `weightUnit` is now a
    /// *derived* detail: with no explicit override it follows the server-owned
    /// ``unitPreference`` binary (metric → kg, imperial → lb); an explicit pick is
    /// preserved as ``weightUnitOverride`` under the UNCHANGED key
    /// `hl.settings.weightUnit`, so existing users keep their choice. "Key unset"
    /// now means "follow the server binary" instead of "kg" — identical for
    /// existing users (unset + metric-default ⇒ kg). BP/glucose stay stored (no
    /// server-binary coupling, plan §0.3.2).
    private(set) var weightUnitOverride: WeightUnit?

    public var weightUnit: WeightUnit {
        get { weightUnitOverride ?? unitPreference.defaultWeightUnit }
        set {
            weightUnitOverride = newValue
            defaults.set(newValue.rawValue, forKey: Keys.weightUnit)
        }
    }

    /// **Build 9 (Server-Prefs) / 9.1** — the server-resolved unit system
    /// (`User.unitPreference`). Server authoritative → mirrored into the single
    /// `HLUnitPreference.defaultsKey` UserDefaults key on hydration; pure readers
    /// use `HLUnitPreference.current(defaults:)`. Default `.metric` until the first
    /// load. Written to the network only by an explicit toggle
    /// (``setUnitPreference(_:)``) or the one flag-guarded migration — never from
    /// hydration/adoption (no ping-pong, no initial write).
    public internal(set) var unitPreference: HLUnitPreference

    public var bloodPressureUnit: BloodPressureUnit {
        didSet { defaults.set(bloodPressureUnit.rawValue, forKey: Keys.bpUnit) }
    }

    public var glucoseUnit: GlucoseUnit {
        didSet { defaults.set(glucoseUnit.rawValue, forKey: Keys.glucoseUnit) }
    }

    /// Value-type snapshot of the three display-unit prefs, handed to the
    /// metric display path (`DashboardMetric.formattedPrimary(units:)` /
    /// `unitSuffix(for:units:)`) so conversion stays a pure transform.
    public var unitPreferences: UnitPreferences {
        UnitPreferences(weight: weightUnit, bloodPressure: bloodPressureUnit, glucose: glucoseUnit)
    }

    /// **v0.5.5.7 COACH-COIN** — operator-dismissible Hero-card flag.
    /// When `true`, `InsightsScreen` hides `AskCoachHeroCard` and surfaces
    /// the collapsed coin in the navigation-bar trailing slot instead.
    /// UI-pref only (no Health-data, no tokens) — UserDefaults is the
    /// canonical storage per PROJECT_GUIDE.md.
    public var coachHeroDismissed: Bool {
        didSet { defaults.set(coachHeroDismissed, forKey: Keys.coachHeroDismissed) }
    }

    /// **v0.14.8 cycle-tracking — explicit opt-in.** UI-pref bool (default
    /// `false`) that force-enables cycle tracking regardless of the
    /// server-side `gender` field. This is the §2-tertiary override from
    /// `RESEARCH-cycle.md`: it lets trans / non-binary women (and the
    /// `"other"` gender value, or a user who skipped the gender field) turn
    /// the feature on explicitly, while it stays invisible to everyone else.
    /// Read by `CycleGate` — never scatter `if gender ==` checks.
    /// UI-pref only (no Health-data, no tokens) → UserDefaults is the
    /// canonical storage per PROJECT_GUIDE.md.
    ///
    /// **Build 9 (Server-Prefs) / 9.3 — RECONCILE-WITH-SERVER eingelöst.** Name +
    /// key + `CycleGate` truth-table UNCHANGED; only the storage is server-synced.
    /// The server-resolved `cycleTrackingEnabled` (mirrored into
    /// ``cycleTrackingServerEnabled``) is adopted into THIS local cache on
    /// hydration (server = source). Writes only from ``setCycleTrackingOptIn(_:)``
    /// or the one flag-guarded 9.3 migration — never from adoption (no ping-pong).
    public var cycleTrackingOptIn: Bool {
        didSet { defaults.set(cycleTrackingOptIn, forKey: Keys.cycleTrackingOptIn) }
    }

    /// **9.3** — mirror of the server-resolved `cycleTrackingEnabled`. `nil` until
    /// the first hydration (old server → stays `nil`, tolerant). `internal(set)`
    /// so the `SettingsStore+ServerPrefs` extension adopts it.
    public internal(set) var cycleTrackingServerEnabled: Bool?

    /// **#13 — compliance-heatmap window length.** Operator-facing pick from
    /// Settings → Erscheinungsbild (4 / 8 / 12 / 26 weeks; 12 = the REG-4
    /// default footprint). `ComplianceHeatmapSection` reads it live through
    /// the `@Observable` environment, so the grid re-lays out on the spot.
    /// UI-pref only (no Health-data, no tokens) → UserDefaults is the
    /// canonical storage per PROJECT_GUIDE.md.
    public var complianceHeatmapWeeks: ComplianceHeatmapWeeks {
        didSet { defaults.set(complianceHeatmapWeeks.rawValue, forKey: Keys.complianceHeatmapWeeks) }
    }

    let repo: SettingsRepository
    let defaults: UserDefaults
    private let swr: SWRCoordinator?
    /// **9.3** — cycle write-leg (`PATCH /api/auth/me/cycle-prefs`) for the toggle
    /// + migration. Internal so the `+ServerPrefs` extension reaches it.
    let cycleRepo: CycleRepository?
    /// **9.3** — server-vs-standalone gate for the explicit cycle toggle (`nil` →
    /// treated as server-backed). Internal for the extension.
    let backend: BackendAvailability?
    private var authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry?
    private var userIDProvider: (@Sendable () -> String?)?

    public init(
        repo: SettingsRepository,
        defaults: UserDefaults = .standard,
        swr: SWRCoordinator? = nil,
        cycleRepo: CycleRepository? = nil,
        backend: BackendAvailability? = nil
    ) {
        self.repo = repo
        self.defaults = defaults
        self.swr = swr
        self.cycleRepo = cycleRepo
        self.backend = backend
        // Biometric-Lock default ON (Spec §7) — `bool(forKey:)` returns false for unset keys,
        // wir müssen also explizit prüfen, ob der User schon eine Wahl getroffen hat.
        if defaults.object(forKey: Keys.biometric) == nil {
            biometricLockEnabled = true
            defaults.set(true, forKey: Keys.biometric)
        } else {
            biometricLockEnabled = defaults.bool(forKey: Keys.biometric)
        }
        dashboardLayout = DashboardLayout(rawValue: defaults.string(forKey: Keys.dashLayout) ?? "") ?? .cards
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        // Build 9 — `weightUnit` became a derived detail. An already-set
        // `hl.settings.weightUnit` stays an explicit per-device override; unset =
        // follow the server binary (`unitPreference.defaultWeightUnit`).
        weightUnitOverride = defaults.string(forKey: Keys.weightUnit).flatMap { WeightUnit(rawValue: $0) }
        // Build 9 — server-resolved unit system, read from the mirror (default
        // `.metric`); adopted from `/api/auth/me` on the first hydration.
        unitPreference = HLUnitPreference.current(defaults: defaults)
        bloodPressureUnit = BloodPressureUnit(rawValue: defaults.string(forKey: Keys.bpUnit) ?? "") ?? .mmHg
        glucoseUnit = GlucoseUnit(rawValue: defaults.string(forKey: Keys.glucoseUnit) ?? "") ?? .mgdL
        // COACH-COIN (v0.5.5.7): defaults to `false` — fresh installs see
        // the Hero card. UserDefaults `bool(forKey:)` returns false for
        // unset keys, which is the intended initial state.
        coachHeroDismissed = defaults.bool(forKey: Keys.coachHeroDismissed)
        // v0.14.8 cycle-tracking opt-in — defaults to `false` (feature stays
        // invisible until a gender match or an explicit opt-in). `bool(forKey:)`
        // returns false for unset keys, which is the intended initial state.
        cycleTrackingOptIn = defaults.bool(forKey: Keys.cycleTrackingOptIn)
        // #13 — heatmap window length. `integer(forKey:)` returns 0 for unset
        // keys, which no case matches → the 12-week REG-4 default applies.
        complianceHeatmapWeeks = ComplianceHeatmapWeeks(
            rawValue: defaults.integer(forKey: Keys.complianceHeatmapWeeks)
        ) ?? .twelve
        // v0.14.7 — "dark-first" default. Dark mode is the canonical, more
        // beautiful look, so the app should land on it out of the box. Unset
        // installs already read `.dark` above; this re-asserts dark ONCE for any
        // device that picked / inherited a non-dark appearance during earlier
        // testing. After this runs the user can freely choose System / Light in
        // Settings → Erscheinungsbild and it persists — the flag stops the
        // re-assert from ever overriding that later choice. Assigning here does
        // not fire `didSet` (init), so the new value is written to defaults
        // explicitly.
        if !defaults.bool(forKey: Keys.darkDefaultReasserted) {
            if appearance != .dark {
                appearance = .dark
                defaults.set(AppearanceMode.dark.rawValue, forKey: Keys.appearance)
            }
            defaults.set(true, forKey: Keys.darkDefaultReasserted)
        }
    }

    /// Live composition-root initializer. Keeps the internal registry out of
    /// public API while still making the boundary an explicit dependency.
    convenience init(
        repo: SettingsRepository,
        defaults: UserDefaults = .standard,
        swr: SWRCoordinator? = nil,
        cycleRepo: CycleRepository? = nil,
        backend: BackendAvailability? = nil,
        authenticatedSessionRegistry: AuthenticatedSessionLeaseRegistry,
        userIDProvider: @escaping @Sendable () -> String?
    ) {
        self.init(repo: repo, defaults: defaults, swr: swr, cycleRepo: cycleRepo, backend: backend)
        self.authenticatedSessionRegistry = authenticatedSessionRegistry
        self.userIDProvider = userIDProvider
    }

    func captureAuthenticatedSessionLease() -> AuthenticatedSessionLease? {
        let ownerID = userIDProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let authenticatedSessionRegistry {
            guard let ownerID, !ownerID.isEmpty else { return nil }
            return authenticatedSessionRegistry.capture(ownerID: ownerID)
        }
        return AuthenticatedSessionLease(
            ownerID: ownerID.flatMap { $0.isEmpty ? nil : $0 } ?? "_anonymous",
            generation: 0,
            current: { true }
        )
    }

    func authenticatedEffectIsCurrent(_ sessionLease: AuthenticatedSessionLease?) -> Bool {
        sessionLease?.isCurrent == true
    }

    public func load() async {
        guard let sessionLease = captureAuthenticatedSessionLease() else {
            // 20-02 — R1's residual: this exit sits ABOVE the covering defer, so
            // it counted the refusal and still returned with `isLoading` as it
            // found it. On a warm install whose session was revoked mid-load
            // that flag is RAISED and nothing lowers it again for the life of
            // the process. Settling is not the publication 09-06 forbids: a nil
            // lease means nobody is here, so there is no newer generation whose
            // skeleton this could erase — the case `ownsRegistryGeneration`
            // exists to distinguish. See `SettingsLeaseSettlementTests`.
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .settings)
            isLoading = false
            return
        }
        // 14-06 — the same strand as `MedicationsStore`, and the reason the
        // operator's avatar is invisible as well as slow: `AppContainer+Avatar`
        // awaits `settings.load()` before it can even read `profile.avatarUrl`,
        // and this method waits for BOTH the profile and the `hkSyncConfig`
        // streams to reach a terminal state. A flag still raised at exit means
        // this load published nothing and left the surface waiting.
        // Guarded on `ownsRegistryGeneration`, not `isCurrent` — see
        // `MedicationsStore.load`. A superseded account's late return must not
        // clear the skeleton the new account's in-flight load is showing.
        defer {
            if sessionLease.ownsRegistryGeneration {
                if isLoading {
                    StoreEffectDiagnostics.recordRefusal(.loadInterrupted, store: .settings)
                }
                isLoading = false
            }
        }
        guard let swr else {
            await loadDirect(sessionLease: sessionLease)
            return
        }
        let repo = repo
        async let profileStream: () = consumeProfile(
            stream: swr.observe(.userProfile, decoding: UserProfile.self, fetch: {
                try sessionLease.requireCurrent()
                let value = try await repo.profile()
                try sessionLease.requireCurrent()
                return value
            }),
            sessionLease: sessionLease
        )
        async let configStream: () = consumeConfig(
            stream: swr.observe(.hkSyncConfig, decoding: HealthKitSyncConfig.self, fetch: {
                try sessionLease.requireCurrent()
                let value = try await repo.healthKitConfig()
                try sessionLease.requireCurrent()
                return value
            }),
            sessionLease: sessionLease
        )
        _ = await (profileStream, configStream)
    }

    /// Direct-fetch path — used when no SWR coordinator is injected (unit
    /// tests). Keeps the old single-emit semantics so existing
    /// `SettingsStoreProfileTests` expectations still hold.
    private func loadDirect(sessionLease: AuthenticatedSessionLease) async {
        isLoading = true
        error = nil
        // 14-06 — see `MedicationsStore.loadDirect`: the old condition folded in
        // cancellation and so skipped the one exit that needed it.
        defer {
            if sessionLease.ownsRegistryGeneration { isLoading = false }
        }
        do {
            try sessionLease.requireCurrent()
            async let profileValue = repo.profile()
            async let configValue = repo.healthKitConfig()
            let (loadedProfile, loadedConfig) = try await (profileValue, configValue)
            try sessionLease.requireCurrent()
            profile = loadedProfile
            hkConfig = loadedConfig
            await hydrateAuthMeExtras(sessionLease: sessionLease)
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            error = err
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    private func consumeProfile(
        stream: AsyncStream<SWRState<UserProfile>>,
        sessionLease: AuthenticatedSessionLease
    ) async {
        for await state in stream {
            guard authenticatedEffectIsCurrent(sessionLease) else {
                StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .settings)
                return
            }
            switch state {
            case .empty:
                isLoading = true
                error = nil
            case let .cached(value, _):
                profile = value
                isShowingStaleCache = true
                isLoading = false
                await hydrateAuthMeExtras(sessionLease: sessionLease)
            case let .fresh(value):
                profile = value
                isShowingStaleCache = false
                isLoading = false
                error = nil
                await hydrateAuthMeExtras(sessionLease: sessionLease)
            case let .failed(err, lastKnown):
                if let lastKnown {
                    profile = lastKnown
                    isShowingStaleCache = true
                    await hydrateAuthMeExtras(sessionLease: sessionLease)
                }
                guard authenticatedEffectIsCurrent(sessionLease) else {
                    StoreEffectDiagnostics.recordRefusal(.leaseRetired, store: .settings)
                    return
                }
                isLoading = false
                error = err
            }
        }
    }

    private func consumeConfig(
        stream: AsyncStream<SWRState<HealthKitSyncConfig>>,
        sessionLease: AuthenticatedSessionLease
    ) async {
        for await state in stream {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            switch state {
            case .empty:
                break
            case let .cached(value, _):
                hkConfig = value
            case let .fresh(value):
                hkConfig = value
            case let .failed(_, lastKnown):
                if let lastKnown { hkConfig = lastKnown }
            }
        }
    }

    /// Apply a diff-payload to the user's profile via `PATCH /api/user/profile`.
    /// Returns `true` on success so the caller can dismiss the edit-sheet only
    /// when the write committed. Errors land in `self.error` for the banner.
    ///
    /// Added v0.4.1 / M2-A6 to back `EditProfileScreen.save()`.
    @discardableResult
    public func updateProfile(_ patch: ProfilePatch) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        guard !patch.isEmpty else { return true }
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        error = nil
        do {
            try sessionLease.requireCurrent()
            let updated = try await repo.patchProfile(patch)
            try sessionLease.requireCurrent()
            profile = updated
            // Mirror to cache so the next observe sees the writer-truth
            // (otherwise the cached arm would emit a stale profile on the
            // next tab-mount before revalidation lands).
            if let swr {
                try sessionLease.requireCurrent()
                await swr.writeThrough(.userProfile, value: updated)
                guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            }
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            error = err
            return false
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// v0.5.4.3 HP5 — toggle the mood-reminder opt-in flag on the
    /// server. Optimistic local update first so the toggle in
    /// `SettingsNotificationsScreen` feels instant; on a non-retriable
    /// error we revert to the previous value + surface the banner.
    ///
    /// Skips the PATCH when the desired value already matches the
    /// in-memory profile — avoids a 304-style no-op write + idempotent
    /// from the UI's perspective.
    @discardableResult
    public func updateMoodReminderEnabled(_ enabled: Bool) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if profile?.moodReminderEnabled == enabled {
            return true
        }
        let previous = profile
        // Optimistic local update — toggle should snap immediately so
        // the user sees the change before the network round-trip.
        if let p = profile {
            profile = UserProfile(
                username: p.username,
                displayName: p.displayName,
                email: p.email,
                avatarUrl: p.avatarUrl,
                dateOfBirth: p.dateOfBirth,
                gender: p.gender,
                heightCm: p.heightCm,
                locale: p.locale,
                timezone: p.timezone,
                moodReminderEnabled: enabled,
                fullName: p.fullName,
                insurerName: p.insurerName,
                insuranceNumber: p.insuranceNumber,
                insurerIkNumber: p.insurerIkNumber,
                timeFormat: p.timeFormat,
                dateFormat: p.dateFormat
            )
        }
        let ok = await updateProfile(ProfilePatch(moodReminderEnabled: enabled))
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        if !ok {
            // Server rejected — revert to the pre-toggle value so the UI
            // doesn't lie about the persisted state.
            profile = previous
        }
        return ok
    }

    // MARK: - Time + date format display preferences (M3 / A360-1 H1)

    /// Effective time-format preference (server `User.timeFormat`), `.auto`
    /// until the profile loads. Settings binds to ``setTimeFormat(_:)``.
    public var timeFormat: HLTimeFormat {
        HLTimeFormat(rawValue: profile?.timeFormat ?? "") ?? .auto
    }

    /// Effective date-format preference (server `User.dateFormat`), `.auto`
    /// until the profile loads. Settings binds to ``setDateFormat(_:)``.
    public var dateFormat: HLDateFormat {
        HLDateFormat(rawValue: profile?.dateFormat ?? "") ?? .auto
    }

    /// Change the time-format preference: optimistic local update + UserDefaults
    /// mirror, then PATCH; reverts on a non-retriable error. Skips a no-op.
    @discardableResult
    public func setTimeFormat(_ format: HLTimeFormat) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if timeFormat == format { return true }
        let previous = profile
        if let p = profile {
            profile = p.replacingTimeFormat(format.rawValue)
        } else {
            defaults.set(format.rawValue, forKey: HLTimeFormat.defaultsKey)
        }
        let ok = await updateProfile(ProfilePatch(timeFormat: .some(format.rawValue)))
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        if !ok { profile = previous
            mirrorTimeFormatPreference()
        }
        return ok
    }

    /// A360-1 H1 — change the date-format preference; mirrors
    /// ``setTimeFormat(_:)`` (optimistic + mirror + PATCH + revert).
    @discardableResult
    public func setDateFormat(_ format: HLDateFormat) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if dateFormat == format { return true }
        let previous = profile
        if let p = profile {
            profile = p.replacingDateFormat(format.rawValue)
        } else {
            defaults.set(format.rawValue, forKey: HLDateFormat.defaultsKey)
        }
        let ok = await updateProfile(ProfilePatch(dateFormat: .some(format.rawValue)))
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        if !ok { profile = previous
            mirrorDateFormatPreference()
        }
        return ok
    }

    /// Mirrors the in-memory `timeFormat` / `dateFormat` into the UserDefaults
    /// keys the pure (`nonisolated static`) formatters read. Called from the
    /// `profile` `didSet` so the mirrors track the server-resolved value.
    private func mirrorTimeFormatPreference() {
        let value = HLTimeFormat(rawValue: profile?.timeFormat ?? "")?.rawValue ?? HLTimeFormat.auto.rawValue
        defaults.set(value, forKey: HLTimeFormat.defaultsKey)
    }

    private func mirrorDateFormatPreference() {
        let value = HLDateFormat(rawValue: profile?.dateFormat ?? "")?.rawValue ?? HLDateFormat.auto.rawValue
        defaults.set(value, forKey: HLDateFormat.defaultsKey)
    }

    public func toggle(syncEntryID: String) async {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return }
        guard var config = hkConfig,
              let i = config.entries.firstIndex(where: { $0.id == syncEntryID }) else { return }
        let entry = config.entries[i]
        let updated = HealthKitSyncEntry(id: entry.id, kind: entry.kind, direction: entry.direction, enabled: !entry.enabled)
        var entries = config.entries
        entries[i] = updated
        config = HealthKitSyncConfig(entries: entries, lastSyncedAt: config.lastSyncedAt)
        hkConfig = config
        do {
            try sessionLease.requireCurrent()
            let saved = try await repo.updateHealthKit(config: config)
            try sessionLease.requireCurrent()
            hkConfig = saved
            if let swr {
                try sessionLease.requireCurrent()
                await swr.writeThrough(.hkSyncConfig, value: saved)
                guard authenticatedEffectIsCurrent(sessionLease) else { return }
            }
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            error = err
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            self.error = .unknown(String(describing: error))
        }
    }

    /// Resets in-memory state on logout. Keychain entries are wiped by `AuthStore`.
    public func clearOnLogout() {
        profile = nil
        hkConfig = nil
        error = nil
        // 14-06 — this line was missing, the same omission 13-03 found in
        // `DashboardStore`. A logout during an in-flight load handed the next
        // account a profile that was already, permanently, loading.
        isLoading = false
        isShowingStaleCache = false
        // COACH-COIN (v0.5.5.7) — Hero-dismiss is per-user UX state. On
        // logout the next signed-in user should see the Hero card again
        // (so the Coach affordance is discoverable). UserDefaults removal
        // keeps the storage consistent with the in-memory reset.
        coachHeroDismissed = false
        defaults.removeObject(forKey: Keys.coachHeroDismissed)
        // Build 9 (Server-Prefs) / 9.1 — the server-owned unit mirror + its
        // migration flag are per-user; the next signed-in user migrates /
        // hydrates fresh. The three device-level picker override keys
        // (`hl.settings.weightUnit` etc.) stay device prefs, as documented.
        unitPreference = .metric
        defaults.removeObject(forKey: HLUnitPreference.defaultsKey)
        defaults.removeObject(forKey: Self.unitPreferenceMigratedKey)
        // Build 9 (Server-Prefs) / 9.3 — cycle opt-in cache + server mirror +
        // migration flag are per-user (also closes the pre-existing gap where the
        // opt-in survived logout).
        cycleTrackingOptIn = false
        defaults.removeObject(forKey: Keys.cycleTrackingOptIn)
        cycleTrackingServerEnabled = nil
        defaults.removeObject(forKey: Self.cycleServerEnabledKey)
        defaults.removeObject(forKey: Self.cycleOptInMigratedKey)
    }

    private enum Keys {
        static let biometric = "hl.settings.biometricLock"
        static let dashLayout = "hl.settings.dashLayout"
        static let appearance = "hl.settings.appearance"
        static let weightUnit = "hl.settings.weightUnit"
        static let bpUnit = "hl.settings.bpUnit"
        static let glucoseUnit = "hl.settings.glucoseUnit"
        static let coachHeroDismissed = "dev.healthlog.app.coach.hero.dismissed"
        static let darkDefaultReasserted = "hl.settings.darkDefault.reasserted.v1"
        static let cycleTrackingOptIn = "hl.settings.cycleTracking.optIn"
        static let complianceHeatmapWeeks = "hl.settings.complianceHeatmap.weeks"
    }
}

/// **#13 — selectable compliance-heatmap window.** Raw value = week count so
/// the UserDefaults round-trip stays human-readable and the grid math can use
/// `rawValue` directly. 12 stays the default (REG-4 operator spec); 26 mirrors
/// the GitHub half-year footprint for long-tenure users; 4/8 give recently
/// started users a denser, honest grid.
public enum ComplianceHeatmapWeeks: Int, CaseIterable, Identifiable, Sendable {
    case four = 4
    case eight = 8
    case twelve = 12
    case twentySix = 26

    public var id: Int {
        rawValue
    }
}

// MARK: - Environment plumbing (v0.11 N1)

//
// The `UnitPreferences` value type + the three unit enums live in
// `Models/UnitPreferences.swift` (HealthLogCore) so the platform-free metric
// formatters can read them. This SwiftUI environment bridge stays app-side.

private struct UnitPreferencesKey: EnvironmentKey {
    static let defaultValue: UnitPreferences = .standard
}

public extension EnvironmentValues {
    /// The user's display-unit prefs, injected at the dashboard/measurement
    /// root from `SettingsStore.unitPreferences`. Tiles read it via
    /// `@Environment(\.unitPreferences)` so the conversion seam needs no
    /// prop-drilling. Defaults to `.standard` (canonical SI, no conversion)
    /// for previews/tests that don't inject it.
    var unitPreferences: UnitPreferences {
        get { self[UnitPreferencesKey.self] }
        set { self[UnitPreferencesKey.self] = newValue }
    }
}

public enum DashboardLayout: String, CaseIterable, Identifiable, Sendable {
    case cards

    public var id: String {
        rawValue
    }
}

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    public var id: String {
        rawValue
    }

    /// Catalog keys, not hardcoded German.
    public var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil // follow system
        }
    }
}
