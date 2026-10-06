import Foundation

// **Build 9 (Server-Prefs) / 9.1** — the `/api/auth/me` hydration extras +
// the server-owned `unitPreference` adopt / toggle / one-time migration, split
// out of `SettingsStore.swift` to keep that type under the length budget
// (PROJECT_GUIDE.md file-length discipline). Pure additive extension — the mirror
// pattern and write invariants are documented on each method.

extension SettingsStore {
    /// One-time unit-preference migration flag (9.1). Survives app restarts so a
    /// second load never re-PATCHes. The mirror key itself is
    /// `HLUnitPreference.defaultsKey` (`hl.settings.unitPreference`).
    static let unitPreferenceMigratedKey = "hl.settings.unitPref.migrated.v1"
    /// **9.3** — mirror of the server-resolved `cycleTrackingEnabled`.
    static let cycleServerEnabledKey = "hl.settings.cycleTracking.serverEnabled"
    /// **9.3** — one-time cycle opt-in migration flag (survives restarts).
    static let cycleOptInMigratedKey = "hl.settings.cycleTracking.migrated.v1"
    /// #108 — the glucose-unit mirror (same key the property's `didSet` writes;
    /// `Keys` is private to the main file).
    static let glucoseUnitDefaultsKey = "hl.settings.glucoseUnit"
    /// #108 — one-time glucose-unit migration flag (survives restarts).
    static let glucoseUnitMigratedKey = "hl.settings.glucoseUnit.migrated.v1"

    /// **Build 9 (Server-Prefs) — one `/api/auth/me` round-trip, two jobs.**
    ///
    /// Supersedes the v0.8.1 avatar-only merge. On every profile emission it
    /// fetches the thin ``AuthMeServerPrefs`` projection ONCE and:
    ///   1. **Avatar splice** — unchanged semantics: only when the in-memory
    ///      profile still lacks an `avatarUrl` does it splice `/me`'s value so the
    ///      `.task(id: profile?.avatarUrl)` display surfaces re-fire. A profile
    ///      that already carries one (a future `/profile` may) is never clobbered.
    ///   2. **unitPreference adoption + one-time migration (9.1)** — adopts the
    ///      server-resolved binary into the property + mirror key (a `nil` from an
    ///      old server leaves the mirror/default untouched → tolerant path), then
    ///      runs the flag-guarded migration. Adoption is NEVER a write (no
    ///      ping-pong); the migration is the only hydration-adjacent write and
    ///      fires at most once.
    ///
    /// Any `/me` transport failure is swallowed: the profile is already valid; the
    /// avatar simply falls back to initials and the mirror keeps its last value.
    func hydrateAuthMeExtras(sessionLease: AuthenticatedSessionLease) async {
        guard authenticatedEffectIsCurrent(sessionLease), profile != nil else { return }
        let prefs: AuthMeServerPrefs
        do {
            try sessionLease.requireCurrent()
            prefs = try await repo.authMeServerPrefs()
            try sessionLease.requireCurrent()
        } catch {
            return
        }

        // (1) Avatar splice — only into an avatar-less snapshot; re-read `profile`
        // after the await in case a concurrent SWR emission replaced it.
        if let avatarURL = prefs.avatarUrl, !avatarURL.isEmpty,
           let latest = profile, latest.avatarUrl == nil
        {
            profile = UserProfile(
                username: latest.username,
                displayName: latest.displayName,
                email: latest.email,
                avatarUrl: avatarURL,
                dateOfBirth: latest.dateOfBirth,
                gender: latest.gender,
                heightCm: latest.heightCm,
                locale: latest.locale,
                timezone: latest.timezone,
                moodReminderEnabled: latest.moodReminderEnabled,
                fullName: latest.fullName,
                insurerName: latest.insurerName,
                insuranceNumber: latest.insuranceNumber,
                insurerIkNumber: latest.insurerIkNumber,
                timeFormat: latest.timeFormat,
                dateFormat: latest.dateFormat
            )
        }

        // (2) unitPreference — adopt + migrate. A `nil` (old server without the
        // field) leaves the mirror + property untouched: no adoption, no write.
        if let raw = prefs.unitPreference, let server = HLUnitPreference(rawValue: raw) {
            adoptUnitPreference(server)
            await runUnitPreferenceMigrationIfNeeded(serverValue: server, sessionLease: sessionLease)
        }
        guard authenticatedEffectIsCurrent(sessionLease) else { return }

        // (2b) #115 1.5 — the resolved account zone. Adopted before anything
        // else awaits again so every day key cut after this read uses it.
        adoptAccountTimeZone(prefs.timezone)

        // (2c) #108 — glucoseUnit: migrate a local-only pick once, then adopt
        // the account's unit. An old server without the key keeps the mirror.
        await reconcileGlucoseUnit(prefs, sessionLease: sessionLease)
        guard authenticatedEffectIsCurrent(sessionLease) else { return }

        // (3) cycleTrackingEnabled (9.3) — MIGRATION BEFORE ADOPTION, else the
        // adoption would overwrite the local opt-in before it is migrated. A
        // `nil` (old server) leaves the opt-in cache + mirror untouched (tolerant).
        if let serverEnabled = prefs.cycleTrackingEnabled {
            let migratedUp = await runCycleOptInMigrationIfNeeded(
                serverValue: serverEnabled,
                sessionLease: sessionLease
            )
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            // If the migration just told the server "enabled", the effective
            // server truth is now `true` — adopt that, not the stale pre-migration
            // `false` this /me fetch reported.
            adoptCycleServerEnabled(migratedUp ? true : serverEnabled)
        }

        // (4) N1 — the account's medication-reminder delivery state, read off
        // this same `/me` payload so the `clientManaged` decision costs no
        // request of its own. Handed over only while the lease still holds.
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        onMedicationReminderServerDelivery?(prefs.medicationReminderDelivery, sessionLease)
    }

    /// Mirror-write helper: hard-set the resolved unit binary into the property
    /// AND the single UserDefaults mirror the pure readers consult. Pure state
    /// sync — never a network write.
    private func adoptUnitPreference(_ value: HLUnitPreference) {
        unitPreference = value
        defaults.set(value.rawValue, forKey: HLUnitPreference.defaultsKey)
    }

    /// **9.1 explicit user toggle.** Optimistic property + mirror, PATCH, revert
    /// on a non-retriable error — the exact ``setTimeFormat(_:)`` form. This is
    /// one of only two paths that ever write `unitPreference` to the network.
    @discardableResult
    public func setUnitPreference(_ value: HLUnitPreference) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if unitPreference == value { return true }
        let previous = unitPreference
        adoptUnitPreference(value)
        error = nil
        do {
            try sessionLease.requireCurrent()
            let echoed = try await repo.setUnitPreference(value.rawValue)
            try sessionLease.requireCurrent()
            adoptUnitPreference(HLUnitPreference(rawValue: echoed) ?? value)
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            adoptUnitPreference(previous)
            error = err
            return false
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            adoptUnitPreference(previous)
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// **9.1 one-time, flag-guarded migration.** The ONLY scenario that needs a
    /// reconciliation write is a local explicit `.lb` weight override diverging
    /// from a server-resolved `.metric` (the operationalised "server never set +
    /// local divergent", plan §0.3.1) — every other combination is a no-op. The
    /// flag ``unitPreferenceMigratedKey`` survives app restarts so a second load
    /// never re-PATCHes.
    ///
    /// Flag-set rules (plan C2): set after a 2xx, OR when no write was needed, OR
    /// on a deterministic 4xx (prevents a retry loop). A transient (5xx / offline)
    /// error leaves the flag UNSET so a later launch retries — an offline first
    /// run must not swallow the migration.
    private func runUnitPreferenceMigrationIfNeeded(
        serverValue: HLUnitPreference,
        sessionLease: AuthenticatedSessionLease
    ) async {
        guard authenticatedEffectIsCurrent(sessionLease) else { return }
        guard !defaults.bool(forKey: Self.unitPreferenceMigratedKey) else { return }
        guard weightUnitOverride == .lb, serverValue == .metric else {
            // No write needed — record the decision so we never re-check.
            defaults.set(true, forKey: Self.unitPreferenceMigratedKey)
            return
        }
        do {
            try sessionLease.requireCurrent()
            let echoed = try await repo.setUnitPreference(HLUnitPreference.imperial.rawValue)
            try sessionLease.requireCurrent()
            adoptUnitPreference(HLUnitPreference(rawValue: echoed) ?? .imperial)
            defaults.set(true, forKey: Self.unitPreferenceMigratedKey)
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return }
            if case let .server(status, _, _) = err, (400 ..< 500).contains(status) {
                defaults.set(true, forKey: Self.unitPreferenceMigratedKey)
            }
            // 5xx / transient: leave the flag unset → retry on the next launch.
        } catch {
            // Transport error — leave the flag unset (retry next launch).
        }
    }

    // MARK: - account time zone (#115 1.5)

    /// The account zone resolved to a `TimeZone`: the `/api/auth/me` zone when
    /// one arrived, else the profile's, else `.current`.
    ///
    /// `/me` carries the zone the server cuts this account's days in (from
    /// v1.39 always resolved: the stored zone, or the instance default when the
    /// stored one is unusable). `/api/user/profile` returns the raw column, so
    /// on an account whose stored zone the server does not accept the two
    /// differ, and only the `/me` one matches the server's day keys. The
    /// profile value stays the fallback for an older server whose `/me` omits
    /// the field.
    public var resolvedProfileTimeZone: TimeZone {
        for raw in [accountTimeZoneIdentifier, profile?.timezone] {
            if let raw, let zone = TimeZone(identifier: raw) { return zone }
        }
        return .current
    }

    /// Adopt the `/me` zone when this device can resolve it, and push it to the
    /// day-key box like a profile change. An absent or unknown identifier is no
    /// statement about the zone: the last one stands.
    private func adoptAccountTimeZone(_ identifier: String?) {
        guard let identifier, TimeZone(identifier: identifier) != nil,
              identifier != accountTimeZoneIdentifier else { return }
        accountTimeZoneIdentifier = identifier
        onProfileTimeZoneChange?(resolvedProfileTimeZone)
    }

    /// Logout: the glucose unit, its mirror + migration flag, and the `/me`
    /// zone belong to the account that is leaving.
    func clearAccountUnitAndZone() {
        glucoseUnit = .mgdL
        defaults.removeObject(forKey: Self.glucoseUnitDefaultsKey)
        defaults.removeObject(forKey: Self.glucoseUnitMigratedKey)
        accountTimeZoneIdentifier = nil
        onProfileTimeZoneChange?(resolvedProfileTimeZone)
    }

    // MARK: - format mirrors (moved from the main file, #115 B5 length budget)

    /// Mirrors the in-memory `timeFormat` / `dateFormat` into the UserDefaults
    /// keys the pure (`nonisolated static`) formatters read. Called from the
    /// `profile` `didSet` so the mirrors track the server-resolved value.
    func mirrorTimeFormatPreference() {
        let value = HLTimeFormat(rawValue: profile?.timeFormat ?? "")?.rawValue ?? HLTimeFormat.auto.rawValue
        defaults.set(value, forKey: HLTimeFormat.defaultsKey)
    }

    func mirrorDateFormatPreference() {
        let value = HLDateFormat(rawValue: profile?.dateFormat ?? "")?.rawValue ?? HLDateFormat.auto.rawValue
        defaults.set(value, forKey: HLDateFormat.defaultsKey)
    }

    // MARK: - glucoseUnit (#108)

    /// The `glucoseUnit` `didSet`: the app-scoped mirror, then everyone outside
    /// this store that shows or takes glucose in the account's unit (#115 B5 —
    /// the App-Group copy the extension reads, the watch snapshot).
    func glucoseUnitDidChange() {
        defaults.set(glucoseUnit.rawValue, forKey: Self.glucoseUnitDefaultsKey)
        onGlucoseUnitChange?(glucoseUnit)
    }

    /// Mirror-write helper for the glucose unit (the property's `didSet` writes
    /// the UserDefaults mirror). Pure state sync — never a network write.
    private func adoptGlucoseUnit(_ value: GlucoseUnit) {
        guard glucoseUnit != value else { return }
        glucoseUnit = value
    }

    /// **#108 — the account's glucose unit.** `/me` sends the raw column
    /// (`null` = never set = mg/dL). The series endpoint converts into the
    /// resolved unit, so the app adopts exactly that resolution.
    ///
    /// One migration runs first, at most once: a device that picked mmol/L
    /// locally while the account column is still `null` (every account before
    /// server #916 — nothing could write it) tells the server once, so the
    /// person's existing choice survives instead of being flipped to mg/dL. A
    /// transient failure leaves the flag unset AND skips adoption, so the
    /// local pick is still there to migrate on the next launch; a 4xx (an older
    /// server without the route) settles the flag and the server's unit wins.
    private func reconcileGlucoseUnit(
        _ prefs: AuthMeServerPrefs,
        sessionLease: AuthenticatedSessionLease
    ) async {
        guard prefs.glucoseUnitPresent else { return }
        guard !defaults.bool(forKey: Self.glucoseUnitMigratedKey) else {
            adoptGlucoseUnit(GlucoseUnit.resolvedServerValue(prefs.glucoseUnit))
            return
        }
        let localPick = defaults.string(forKey: Self.glucoseUnitDefaultsKey).flatMap(GlucoseUnit.init(rawValue:))
        guard prefs.glucoseUnit == nil, localPick == .mmolL else {
            defaults.set(true, forKey: Self.glucoseUnitMigratedKey)
            adoptGlucoseUnit(GlucoseUnit.resolvedServerValue(prefs.glucoseUnit))
            return
        }
        switch await patchGlucoseUnit(.mmolL, sessionLease: sessionLease) {
        case let .stored(echoed):
            defaults.set(true, forKey: Self.glucoseUnitMigratedKey)
            adoptGlucoseUnit(echoed)
        case .refused:
            defaults.set(true, forKey: Self.glucoseUnitMigratedKey)
            adoptGlucoseUnit(GlucoseUnit.resolvedServerValue(prefs.glucoseUnit))
        case .transient, .superseded:
            break
        }
    }

    /// **#108 explicit user pick.** Optimistic property + mirror, PATCH, adopt
    /// the echo; any failure reverts, so the tiles never show a unit the server
    /// is not converting the series into. Without a server (standalone) the
    /// pick is local only — there is no series to disagree with.
    @discardableResult
    public func setGlucoseUnit(_ value: GlucoseUnit) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        if glucoseUnit == value { return true }
        let previous = glucoseUnit
        adoptGlucoseUnit(value)
        guard backend?.hasServer ?? true else { return true }
        switch await patchGlucoseUnit(value, sessionLease: sessionLease) {
        case let .stored(echoed):
            adoptGlucoseUnit(echoed)
            return true
        case .superseded:
            return false
        case .refused, .transient:
            adoptGlucoseUnit(previous)
            return false
        }
    }

    /// How one glucose-unit PATCH ended: stored (with the echoed unit), refused
    /// by the server (4xx — settle, do not retry), transient (offline / 5xx —
    /// retry later), or superseded (the session changed while it ran).
    enum GlucoseUnitWrite {
        case stored(GlucoseUnit)
        case refused
        case transient
        case superseded
    }

    /// The one network write for the glucose unit, fenced on the lease on both
    /// sides of the await. Publishes the error for the banner.
    private func patchGlucoseUnit(
        _ value: GlucoseUnit,
        sessionLease: AuthenticatedSessionLease
    ) async -> GlucoseUnitWrite {
        do {
            try sessionLease.requireCurrent()
            let echoed = try await repo.setGlucoseUnit(value.serverValue)
            try sessionLease.requireCurrent()
            return .stored(GlucoseUnit.resolvedServerValue(echoed))
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .superseded }
            self.error = err
            return err.isClientRefusal ? .refused : .transient
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return .superseded }
            self.error = .unknown(String(describing: error))
            return .transient
        }
    }

    // MARK: - cycleTrackingOptIn (9.3)

    /// Adopt the server-resolved cycle flag into the mirror AND the local
    /// `cycleTrackingOptIn` cache the `CycleGate` reads (server = source, local =
    /// cache — the RECONCILE contract). Pure state sync — never a network write.
    private func adoptCycleServerEnabled(_ value: Bool) {
        cycleTrackingServerEnabled = value
        defaults.set(value, forKey: Self.cycleServerEnabledKey)
        cycleTrackingOptIn = value
    }

    /// **9.3 explicit user toggle** — optimistic local (the `CycleGate` cache),
    /// then `PATCH /api/auth/me/cycle-prefs {enabled}` (deep-merge) in server mode,
    /// revert on error. Standalone / no server → local only (prior behaviour).
    @discardableResult
    public func setCycleTrackingOptIn(_ enabled: Bool) async -> Bool {
        guard let sessionLease = captureAuthenticatedSessionLease() else { return false }
        let previous = cycleTrackingOptIn
        cycleTrackingOptIn = enabled
        // Standalone (or no repo) → local-only, exactly as before Build 9.
        guard backend?.hasServer ?? true, let cycleRepo else { return true }
        error = nil
        do {
            try sessionLease.requireCurrent()
            _ = try await cycleRepo.updatePrefs(CyclePrefsPatch(enabled: enabled))
            try sessionLease.requireCurrent()
            cycleTrackingServerEnabled = enabled
            defaults.set(enabled, forKey: Self.cycleServerEnabledKey)
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            cycleTrackingOptIn = previous
            error = err
            return false
        } catch {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            cycleTrackingOptIn = previous
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// **9.3 one-time, flag-guarded migration.** The ONLY scenario that needs a
    /// reconciliation write is a local opt-in `true` diverging from a
    /// server-resolved `false` (plan §0.3.1). Local `false` (the default) never
    /// writes. Returns `true` iff it successfully PATCHed `enabled:true` (so the
    /// caller adopts the migrated-up value instead of the stale server `false`).
    /// Flag-set rules match 9.1 (2xx / no-write / 4xx set the flag; a transient
    /// leaves it unset to retry).
    private func runCycleOptInMigrationIfNeeded(
        serverValue: Bool,
        sessionLease: AuthenticatedSessionLease
    ) async -> Bool {
        guard authenticatedEffectIsCurrent(sessionLease) else { return false }
        guard !defaults.bool(forKey: Self.cycleOptInMigratedKey) else { return false }
        guard cycleTrackingOptIn, !serverValue, let cycleRepo else {
            // No write needed (or no repo) — record the decision so we never re-check.
            defaults.set(true, forKey: Self.cycleOptInMigratedKey)
            return false
        }
        do {
            try sessionLease.requireCurrent()
            _ = try await cycleRepo.updatePrefs(CyclePrefsPatch(enabled: true))
            try sessionLease.requireCurrent()
            defaults.set(true, forKey: Self.cycleOptInMigratedKey)
            return true
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(sessionLease) else { return false }
            if case let .server(status, _, _) = err, (400 ..< 500).contains(status) {
                defaults.set(true, forKey: Self.cycleOptInMigratedKey)
            }
            return false
        } catch {
            // 5xx / transient — leave the flag unset → retry on the next launch.
            return false
        }
    }
}

private extension HLError {
    /// A 4xx answer: the server looked at the request and said no. Retrying the
    /// same body gets the same answer (an older server without the route, a
    /// value it does not accept).
    var isClientRefusal: Bool {
        guard case let .server(status, _, _) = self else { return false }
        return (400 ..< 500).contains(status)
    }
}
