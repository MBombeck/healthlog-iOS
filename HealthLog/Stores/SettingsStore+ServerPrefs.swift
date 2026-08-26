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
