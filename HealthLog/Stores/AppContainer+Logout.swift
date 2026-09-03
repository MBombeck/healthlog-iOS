import Foundation

// MARK: - Local logout teardown

/// Reason a logout cascade was kicked off. Lets the shared helper take the
/// extra steps that only apply to certain paths (outbox + GLP-1 wipe on
/// account-deletion) without forking three near-identical closures.
///
/// Added in v0.7.0 W-LOGOUT (security finding NEW-H-1): the previous shape
/// had `handleLocalLogout()` as the canonical helper used only by the
/// "switch server" path, while `AuthStore.logout()`, the APIClient 401
/// bridge, and the account-deletion hook each ran their own slightly
/// different inline cleanup. The drift meant a normal sign-out → sign-in
/// on the same device leaked previous-user data through the on-device AI
/// caches (briefing + trend), avatar PNG, Coach SwiftData transcript,
/// HK diagnostics counters, and the outbox AES-GCM key.
public enum LogoutReason: Sendable, Equatable {
    /// User tapped "Abmelden" in Profile / Einstellungen. Server-side
    /// `/api/auth/logout` already ran; the local cascade is purely device
    /// hygiene before the phase flips to `.unauthenticated`.
    case userInitiated
    /// APIClient observed a terminal 401 (post single-flight refresh).
    /// Phase transition is driven by `AuthStore.handleUnauthorized()`; the
    /// cascade fires alongside it.
    case tokenExpired
    /// User confirmed "Konto löschen". Server-side DELETE already ran;
    /// adds outbox + GLP-1 local-only repo wipe on top of the standard
    /// cleanup because those rows are about to become unreachable garbage
    /// against a deleted account.
    case accountDeleted
    /// User changed the server URL from Settings → Server. Runs the full
    /// device-hygiene cascade like `.userInitiated`, but ALSO clears the
    /// outbox queue + cipher key (`clearsOutbox`): the queued writes were
    /// minted against the previous server's IDs and must not replay
    /// against the new host. The local-only GLP-1 store is server-agnostic
    /// and survives the switch.
    case switchServer

    /// Whether the cascade should clear the encrypted outbox queue **and**
    /// the outbox AES-GCM cipher key. The two are bound together (v0.7.1
    /// C-1 invariant): clearing the rows without wiping the key would leak
    /// the key into the next session, and wiping the key without clearing
    /// the rows would strand them mathematically undecryptable so
    /// `OutboxStore.snapshot()` drops them — silently destroying queued
    /// writes. So both move as one.
    ///
    /// Two paths clear the outbox, for different reasons:
    ///
    /// - `.accountDeleted` — the rows are about to point at a deleted
    ///   account; keeping them would replay garbage and leak the
    ///   predecessor's payload to the next user on the device.
    /// - `.switchServer` — the queued optimistic writes were minted
    ///   against the **previous** server's IDs + idempotency keys. After
    ///   re-pointing the app at a *different* host, replaying them would
    ///   POST the old account's data into the new server (wrong account,
    ///   wrong context). They must not survive the switch. (v0.7.1 C-1
    ///   reconcile-followup: the C-1 fix initially grouped `.switchServer`
    ///   with the benign same-account paths, but switch-server re-targets
    ///   a genuinely different server — see `SettingsServerScreen.commit()`
    ///   "outbox + caches were populated against the previous server's
    ///   IDs". It belongs with account-deletion for the outbox, not with
    ///   the row-preserving paths.)
    ///
    /// `.userInitiated` / `.tokenExpired` KEEP both — same account, same
    /// server, so a follow-up sign-in replays the pending writes. The key
    /// MUST survive with the rows or they become undecryptable.
    ///
    /// **v0.13 WS correction (do not restore the old claim):** these two
    /// kept-row paths do NOT by themselves prevent cross-user leakage. The
    /// per-install cipher key survives the logout, so a *different* user
    /// signing in on the same device reuses the same key and CAN decrypt the
    /// predecessor's leftover ciphertext rows — and since WC widened the kept
    /// set so token-expiry creates now persist, those rows could replay under
    /// the new user's bearer token (User A's data POSTed into User B's
    /// account). Cross-user safety is now enforced one layer up, in
    /// `OutboxReplayService.runOnce`: every row is stamped with its owning
    /// `KeychainKey.userID` at enqueue and a row whose owner ≠ the current
    /// signed-in user is dead-lettered, never replayed. The earlier
    /// "a different user is a fresh login that mints its own key … no leftover
    /// rows under the old key" reasoning was wrong (the key is per-install,
    /// not per-user) and has been removed.
    ///
    /// `internal` (not `fileprivate`) so the C-1 regression suite can pin
    /// the gate value via `@testable import` — a flip would silently
    /// re-orphan kept rows.
    var clearsOutbox: Bool {
        self == .accountDeleted || self == .switchServer
    }

    /// Whether the cascade should additionally wipe the local-only GLP-1
    /// repository (titration ladder, side-effects logbook, pen inventory).
    /// Account-deletion only: that data is local-only and not tied to any
    /// server, so it should survive a server switch (the same user simply
    /// re-points the app) but must be erased when the account itself is
    /// deleted.
    var clearsLocalRepos: Bool {
        self == .accountDeleted
    }

    /// Whether the cascade should wipe the **standalone local mirror**
    /// (`localRepo`) — the offline-mode measurement/intake history.
    ///
    /// **v0.11 marathon (RISK-2 fix):** wiped on `.accountDeleted` **and**
    /// `.switchServer`, NOT only on delete. The mirror is the offline
    /// history that the adopt-upload hook pushes into whatever account the
    /// user next pairs (`AuthStore.adoptUploadHook`). Unlike the GLP-1 store
    /// it is NOT a server-agnostic personal ledger that "the same user simply
    /// re-points": a server switch can move between two *different* accounts
    /// (standalone → pair account A → switch server → standalone → pair
    /// account B). Keeping the mirror across that switch would adopt-upload
    /// account A's offline history into account B — a cross-account data
    /// leak. So the mirror dies with the server context, leaving only the
    /// row-preserving same-account paths (`.userInitiated` / `.tokenExpired`)
    /// — where the standalone history legitimately belongs to the same
    /// signed-in/standalone identity — to keep it.
    var clearsStandaloneMirror: Bool {
        self == .accountDeleted || self == .switchServer
    }
}

public extension AppContainer {
    /// **AUD-7 H1 / 06-05 — the EXPLICIT logout-clearing registry.**
    ///
    /// Every stored `AppContainer` property that conforms to `LogoutClearable`,
    /// listed LITERALLY in stored-property declaration order. Plan 06-05
    /// removed the former runtime-reflection (`Mirror`) discovery: production
    /// PHI-wipe membership must be compiler-reviewable, never inferred at
    /// runtime. `LogoutCompletenessTests` keeps a TEST-side reflection canary
    /// (`productionRegistryIsExplicitAndExactlyComplete`) that fails with the
    /// missing/duplicate/unknown property label when this list drifts from the
    /// conforming stored-property set — so a new `LogoutClearable` store must
    /// be appended here (and classified in the test registry) before it ships.
    ///
    /// Built fresh on each call (logout is rare) to avoid `init`-ordering
    /// hazards; iteration order matches declaration order, preserving the
    /// pre-06-05 clear order of the reflection sweep.
    var logoutClearables: [any LogoutClearable] {
        [
            syncModeStore,
            dashboardStore,
            dashboardLayoutStore,
            insightsLayoutStore,
            measurementsStore,
            medicationsStore,
            deliveryPreferencesStore,
            moodStore,
            cycleStore,
            moodTagCatalogStore,
            moodTagManagementStore,
            insightsStore,
            dailyBriefingStore,
            healthScoreStore,
            achievementsStore,
            settingsStore,
            labsStore,
            customMetricsStore,
            nutrientStore,
            environmentStore,
            illnessStore,
            documentsStore,
            allergiesStore,
            familyHistoryStore,
            mentalHealthStore,
            aiProviderStore,
            chartsStore,
            trendsOverlayStore,
            doctorReportStore,
            localDoctorReportStore,
            disclaimerAckStore,
            onboardingTourStore,
            diabetesStore,
            injectionSitePrefsStore,
            coachNudgeStore,
            coachCadenceSuggestionsStore,
            passkeyManagementStore,
            accountSecurityStore,
            sessionsStore,
            mfaEnrollmentGateStore,
            withingsIntegrationStore,
            whoopIntegrationStore,
            ouraIntegrationStore,
            polarIntegrationStore,
            fitbitIntegrationStore,
            stravaIntegrationStore,
            nightscoutIntegrationStore,
            avatarStore,
            hkReadinessStore,
            wellnessCardVisibilityStore,
            featureFlagsStore,
            liveHealthKitTodayStore
        ]
    }

    /// Single source of truth for every "user is no longer signed in to
    /// this device" cascade. Invoked by:
    ///
    /// 1. `AuthStore.onPostLogoutHook` after `AuthService.logout()` returns
    ///    (`.userInitiated`).
    /// 2. The APIClient 401 bridge after `AuthStore.handleUnauthorized()`
    ///    fires (`.tokenExpired`).
    /// 3. The account-deletion `localCleanupHook` after the server DELETE
    ///    returns 2xx (`.accountDeleted`).
    /// 4. `SettingsServerScreen.commit()` when the user re-targets the app
    ///    at a different server (`.switchServer`).
    ///
    /// Cascade order (security-sensitive — do NOT reshuffle without
    /// reading `.planning/v070-marathon/v070-A-SEC-3-deep.md`):
    ///
    /// 1. Drop the SWR + server-stats repo caches first so the next
    ///    sign-in's first paint can never surface previous-user payloads
    ///    through a hot launch.
    /// 2. Clear the encrypted outbox queue on account-deletion AND
    ///    switch-server (rows point at a deleted account / the previous
    ///    server); clear the local-only GLP-1 store on account-deletion
    ///    only; wipe the standalone local mirror on account-deletion AND
    ///    switch-server (RISK-2 — it adopt-uploads into the next paired
    ///    account, so it must not survive a server/account change).
    /// 3. Wipe the outbox AES-GCM key from Keychain in lockstep with the
    ///    row clear above so the next sign-in generates a fresh cipher key
    ///    on first enqueue (v0.6.2.3 F3-SEC; v0.7.1 C-1 invariant).
    /// 4. Reset the in-process @MainActor stores (settings, measurements,
    ///    medications, …) so any retained SwiftUI snapshots paint empty
    ///    before the new session loads.
    /// 5. Drop the on-device AI caches (briefing + trend + HK sync
    ///    diagnostics + avatar PNG cache) — those caches keyed on the
    ///    previous user but were not wired into any other invalidation
    ///    path before v0.7.0.
    /// 6. Wipe the Coach SwiftData transcript (in-memory + persisted) +
    ///    drop the cached conversation store so the next AskCoach open
    ///    re-hydrates against the new partition.
    /// 7. Drain the notifications inbox so APN-delivered messages tied
    ///    to the previous user can never surface.
    ///
    /// Async because the notifications inbox is resolved lazily off the
    /// launch tick (PA5 Bottleneck #1) and the SwiftData open may not
    /// have completed by the time logout fires.
    ///
    /// **06-05 — sole awaited terminal teardown orchestrator.** Before any
    /// cache/store clearing this cascade (a) invalidates the shared
    /// authenticated-session lease so no suspended producer can publish into
    /// the closing session, and (b) cancels AND awaits every registered
    /// owned-task drain (measurements hydration / latest-page HealthKit
    /// mirror / historical backfill from 06-03). Both steps are idempotent, so
    /// entry points that already staled the lease at their own commitment
    /// point (401 bridge, native/web deletion) simply re-assert it here.
    func performFullLocalLogout(reason: LogoutReason) async {
        // 0a. Invalidate the shared lease FIRST (06-05 step 1).
        authenticatedSessionRegistry.invalidate()
        // 0b. Cancel and await every owned authenticated task (06-05 step 2)
        // so old-account async work is quiescent before anything is cleared
        // and before any replacement session can be admitted by the caller.
        await drainAuthenticatedSessionWork()

        // 1. Cache invalidation first — the @MainActor store wipes below
        // only clear in-memory snapshots; the SWR coordinator + server-
        // stats repo actors hold their own caches that re-paint stale
        // data on next foreground if we don't drop them here. A2-Audit
        // §9 R8 + V0.5.2 R2 / H1.
        await swr.invalidateAll()
        await serverStatsRepos.invalidateAll()

        // 1b. URLCache PHI residue sweep (Data-Privacy audit H1). The three
        // authenticated `APIClient` sessions run on `URLSessionConfiguration
        // .default`, whose on-disk `URLCache` can retain cacheable GET response
        // bodies (measurements / medications / labs / cycle JSON) in
        // `Library/Caches/<bundle>/Cache.db` — an OS-level surface the
        // registry-driven store sweep below cannot reach, so it otherwise survives
        // logout AND account deletion. Purge it in lockstep with the in-process
        // cache invalidation above so no PHI JSON outlives the signed-in user.
        await api.purgeCachedResponses()

        // 2. Outbox + local-repo clear. Two independent gates:
        //  - `clearsOutbox` (account-deletion OR switch-server): the
        //    encrypted queue is dropped because its rows either point at a
        //    deleted account or were minted against the previous server.
        //  - `clearsLocalRepos` (account-deletion only): the local-only
        //    GLP-1 store is server-agnostic, so it survives a server
        //    switch but is erased when the account is deleted.
        if reason.clearsOutbox {
            await outbox.clearAll()
        }
        if reason.clearsLocalRepos {
            // W-PHI-HARDENING precedent — a PHI wipe failure is a hard
            // shared-device invariant, so it is NO LONGER a silent `try?`. If the
            // local-only GLP-1 store genuinely can't be cleared, the logout path
            // must KNOW (logged, sanitised, no PHI) rather than pass it by. The
            // cascade continues regardless (best-effort teardown).
            do {
                try await glp1LocalRepo.deleteAll()
            } catch {
                HLLog.storage.error(
                    "logout GLP-1 local-repo wipe failed — previous-user PHI may linger: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
        // v0.11 marathon (RISK-2) — the standalone local mirror is NOT
        // server-agnostic the way the GLP-1 store is: the adopt-upload hook
        // pushes it into whatever account the user next pairs, so it must die
        // with the server context. Wipe on account-deletion AND server-switch
        // (`clearsStandaloneMirror`) so a switch between two different paired
        // accounts can never adopt-upload the prior account's offline history
        // into the next one. The earlier W1 reasoning that grouped it with the
        // account-deletion-only GLP-1 gate was wrong and has been removed.
        if reason.clearsStandaloneMirror {
            // W-PHI-HARDENING precedent — surface (don't swallow) a wipe failure
            // of the standalone offline mirror: if it survives, the adopt-upload
            // hook could push the prior account's offline history into the next
            // paired account (RISK-2 cross-account leak). Logged sanitised; the
            // cascade continues.
            do {
                try await localRepo.deleteAll()
            } catch {
                HLLog.storage.error(
                    "logout standalone-mirror wipe failed — previous-user PHI may linger: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        // 3. Outbox cipher-key wipe (v0.6.2.3 F3-SEC). Pre-v0.6.2.3 the
        // per-install AES-GCM key for the encrypted outbox payload column
        // survived both logout AND account-deletion. A second user
        // signing in on the same device then inherited the previous
        // user's cipher — any leftover ciphertext row (eg. a stalled
        // BG-replay row that wrote pre-401) decrypted under the new
        // session's `currentUserId`, leaking the predecessor's queued
        // payload. Wipe here so the next sign-in generates a fresh key
        // on first enqueue.
        //
        // **v0.7.1 fix (C-1):** gate the key wipe on the SAME condition
        // as the row clear above (step 2) — `reason.clearsOutbox`. The key
        // and the rows it decrypts always move together:
        //  - When the rows are KEPT (`.userInitiated` / `.tokenExpired`) so
        //    a same-account re-login replays pending optimistic writes,
        //    wiping the key would strand those rows mathematically
        //    undecryptable — `OutboxStore.snapshot()` then deletes every
        //    row it cannot decrypt, silently destroying the very writes
        //    step 2 set out to protect.
        //  - When the rows are CLEARED (`.accountDeleted` / `.switchServer`)
        //    the key is wiped with them, so cross-user / cross-server
        //    leakage is covered: the next sign-in mints a fresh key on
        //    first enqueue, with no leftover rows under the old key.
        if reason.clearsOutbox {
            // Build 273 (A2) — the signed-out-user memo exists only to attribute
            // outbox rows; it goes wherever the rows go.
            try? keychain.remove(forKey: KeychainKey.lastSessionUserID)
            // W-PHI-HARDENING precedent — the outbox AES-GCM key wipe is a hard
            // cross-user/cross-server invariant (a surviving key lets the next
            // sign-in decrypt leftover ciphertext rows). Surface a failure
            // (sanitised, no secret material) instead of the former silent `try?`;
            // the cascade continues so the rest of the teardown still runs.
            do {
                try keychain.remove(forKey: KeychainKey.outboxPayloadKey)
            } catch {
                HLLog.security.error(
                    "logout outbox cipher-key wipe failed — key may survive for the next session: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        // 3b. Reset every user-scoped AI choice on ALL session-end reasons:
        // provider grants/declines, provider-less server-managed consent, BYO
        // consent, the local-only AI-mode flag, and pending picker intents.
        // Keeping this as one API prevents a newly added consent namespace from
        // drifting out of the logout boundary. Idempotent on repeated teardown.
        aiConsentStore.resetForSessionEnd()
        // v0.13 W2 — wipe the BYO API **key bytes** in lockstep with the consent
        // grant above. The key is the secret half (the grant is just consent);
        // both must be gone before the next user touches the device so a shared
        // device can never inherit a working device→provider key. Idempotent.
        BYOKeyStore(keychain: keychain).wipeAll()

        // 4. @MainActor store resets. The 401 bridge previously also
        // called `store.handleUnauthorized()` here — that path stays
        // outside this helper because (a) it transitions auth phase,
        // which only the bridge wants, and (b) it lives in the
        // HealthLogCore module which can't import AppContainer.
        unauthorizedRef.reset()

        // **AUD-7 H1 / 06-05 — registry-driven store clear.** Every
        // `LogoutClearable` stored `AppContainer` property (the ~50 plain
        // synchronous `clearOnLogout()` stores — settings, measurements,
        // medications, labs/illness, dashboard/charts/insights, all
        // integration-status stores, mood-tag catalogs, AI-provider draft,
        // etc.) is iterated here through the EXPLICIT `logoutClearables` list
        // above. `LogoutCompletenessTests` keeps a test-only reflection canary
        // asserting the explicit registry == the conforming stored-property
        // set exactly, so a forgotten/duplicate/stale entry fails at test time
        // (the B187 leak class) while production stays reflection-free.
        //
        // The ASYNC / lifecycle outliers below stay explicit — they aren't a
        // plain `clearOnLogout()`: `MeasurementRemindersStore.clearOnLogout()`
        // is `async`; `MoodHealthSyncStore` / `CycleStore` carry an `async`
        // `deactivateOnLogout()` (importer stop) ON TOP of the sync clear the
        // registry already runs; `ServerStatsStores` is a value-type bundle.
        for clearable in logoutClearables {
            clearable.clearOnLogout()
        }

        // v0.15 W-FRONTDOORS — Vorsorge reminders. `clearOnLogout()` is `async`
        // here (not in the registry); the next user must never inherit the
        // previous user's preventive-care reminders.
        await measurementRemindersStore.clearOnLogout()
        // W-THRESHOLD-NUDGE — drop the per-breach debounce map so the next user
        // never inherits the previous user's out-of-range nudge history. The map
        // holds breach keys (biomarker id / analyte name), not values; clearing
        // it on logout keeps the device clean for the next account. Static wipe.
        ThresholdNudgeDebounceStore.clearAll()
        // v0.8.4 WWIDGET-2 — reset the App Group widget snapshot so the previous
        // user's next dose / compliance / mood / score / latest measurement never
        // lingers on the Home / Lock Screen for the next user on a shared device.
        //
        // W-PHI-HARDENING (reliability audit H4) — this clear is a hard
        // shared-device PHI invariant, so the failure is NO LONGER a silent
        // `try?`. The snapshot is the only at-rest widget PHI; if the App-Group
        // write genuinely can't complete, the logout path must KNOW (logged,
        // no PHI) rather than pass it by. `reset()` still reloads every widget
        // timeline regardless of the write outcome (its own `defer`), so the
        // widgets get a best-effort repaint to their empty/placeholder state
        // even on a write failure; the cascade continues either way. 09-03 — it
        // is AWAITED too: admission closes, the epoch retires and the queued widget writes drain before the placeholder lands.
        do {
            try await widgetSnapshotWriter.reset()
        } catch {
            HLLog.storage.error(
                "logout widget-snapshot reset failed — previous-user widget PHI may linger: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
        }
        // Privacy H4 (audit-v0162) — mirror the widget reset onto the watch. The
        // watch snapshot (med names + doses + mood + latest measurement) lives in
        // the paired watch's own App Group container, which the store-object
        // reflection cascade cannot reach; push a PHI-free placeholder so the
        // watch app + complications clear on the next tick. Best-effort on every
        // logout reason.
        resetWatchSnapshotOnLogout()
        // W-B187 QOL-2 — tear down the CoreSpotlight index so the previous
        // user's medication names never surface in system search after sign-
        // out (PHI residue). Fire-and-forget off the main actor.
        spotlightCoordinator.clearAll()
        // v0.10.0 W10 M2 — force the Apple-Health mood-sync toggle off + reset
        // the per-user State-of-Mind import anchor. Without this, the next user
        // on the same device re-imports the previous user's full HKStateOfMind
        // history into their account. The importer still holds the just-logged-
        // out user's anchor key here, so the reset targets the correct partition.
        // (The in-memory store reset already ran via the registry; this is the
        // `async` importer-stop half.)
        await moodHealthSyncStore.deactivateOnLogout()
        // GH #47 — force the Apple-Health medications toggle off + clear the
        // per-user mirror registry so the next user on the device never inherits
        // the prior user's concept → med-id map.
        await medicationHealthSyncStore.deactivateOnLogout()
        // GH #74 — force the Apple-Health ECG upload switch off + clear the
        // per-user HealthKit cursor. Consent to upload a cardiac waveform is the
        // most personal switch on this device and must never be inherited; and a
        // cursor left behind would let the next user's first sweep silently skip
        // everything that arrived while the switch was off.
        await ecgHealthSyncStore.deactivateOnLogout()
        // v0.14.8 W3 (AUDIT-SECURITY-B175 H-1) — stop the cycle HK import
        // observer + reset its per-user anchors. Without this the importer kept
        // running under the next user's token (device cycle samples uploaded
        // into the wrong account). The in-memory cycle state (calendar /
        // predictions / profile) was already dropped via the registry's
        // `CycleStore.clearOnLogout()`; this is the `async` importer-stop half.
        await cycleStore.deactivateOnLogout()
        // v0.7.0 W-SEC-M-1 — wipe any doctor-report PDF/FHIR residue
        // left behind in `temporaryDirectory`. The store-level
        // `clearOnLogout` only knows the URLs it currently tracks; a
        // crash-during-render or a previous-session render whose URL
        // was never assigned to the @Observable property would leak
        // PHI bytes through to the next user. Pass `ttl: 0` to wipe
        // every owned file unconditionally.
        _ = DoctorReportTmpSweeper.sweep(ttl: 0)
        // #30 — `ModuleGate` is not a `…Store` (not in the registry); the next
        // user re-loads their own module map.
        moduleGate.clearOnLogout()
        // Server-stats stores (V052-A7). The 401 bridge cleared these
        // inline pre-v0.7.0; the standard `handleLocalLogout()` did
        // NOT, which meant a user-tap sign-out left behind workouts +
        // PR + insights-target snapshots that the next user inherited.
        // v0.14.8 W3 (AUDIT-SECURITY-B175 M-1) — the canonical bundle helper
        // clears ALL 13 members (it's a value-type bundle, not in the
        // `LogoutClearable` registry of class instances). The previously
        // duplicated per-member calls (personalRecords / insightsTargets /
        // sourcePriority / rhythmEvents / derivedMetrics / narrative) were
        // redundant subsets of this bundle and have been removed.
        serverStatsStores.clearOnLogout()
        // v1.15 W-WORKOUT — reset the per-user HKWorkout import anchor + stop
        // the observer. Mirrors the Mood / Cycle reset rationale: without this,
        // the next user on the same device would re-import the previous user's
        // full HKWorkout history into their account (the importer still holds
        // the just-logged-out user's anchor key here, so the reset targets the
        // correct partition). No-op when no importer is live or on non-HK builds.
        await healthKit?.resetWorkoutImportObserver()
        // W-HKREAD — same logout rationale for the categorical-EVENT importer:
        // reset every per-type event anchor + stop the observers so the next
        // user on the same device starts clean (never re-imports the prior
        // user's flagged cardiac / mobility events).
        await healthKit?.resetEventImportObserver()
        // 08-06 — the clinician-reviewer-name wipe went with the feature. No
        // surface reads the legacy UserDefaults blob or Keychain name slot, so
        // no previous user's typed name can paint, and the account-delete
        // sweep still covers the shared service it lived under. Deliberately no
        // targeted purge: naming those keys again is the residue removed here.

        // 5. On-device AI caches + avatar PNG. QC-1 / Arch-H3 reconcile:
        // both the briefing hero + trend observation strings were
        // leaking previous-user data across logouts. BF-5 added the
        // HK diagnostics counter reset; v0.5.5 W-UX-1 added the
        // avatar PNG sweep. All four were ONLY wired into
        // `handleLocalLogout()` (the switch-server path) pre-v0.7.0 —
        // every other logout path skipped them.
        OnDeviceBriefingCache.shared.clearOnLogout()
        TrendObservationCache.shared.clearOnLogout()
        HKSyncDiagnostics.shared.reset()
        await AvatarCache.shared.clearAll()

        // 6. Coach chat transcript hygiene (v0.5.7 G.5). See helper
        // below — handles both the in-memory chat store + the
        // SwiftData persistence layer.
        wipeCoachChatOnLogout()

        // 6b. W-B187 (AUDIT-SEC-b187 B1 + High) — wipe the Mini-Coach box, the
        // ONE per-user store cache the cascade previously skipped. It backs the
        // *computed* `coachAboutMeStore` / `miniCoachStore` properties, so the
        // reflection-based LogoutCompletenessTests registry could not see it and
        // the leak went uncaught. Without this wipe an A→B account switch
        // rendered User A's self-context PHI (conditions / allergies / coach-
        // focus) to User B through the un-reloaded About-Me editor, and the
        // in-session coach conversation stranded too. Drops the cached service
        // (carrying the actor-side MiniCoachHistory turns), the conversation
        // store, and the About-Me store — after first wiping their in-memory PHI
        // so no SwiftUI re-paint flashes the predecessor's data.
        await MiniCoachBox.shared.clearStores(for: self)

        // Build 6 / Item 6.6 — drop the box-cached Coach/AI privacy store so the
        // next user on a shared device never inherits the previous user's
        // `documentsAutoAiRead` / `insightsPrivacyMode` flags before their own
        // load. Preference flags (not PHI), so this rides its own dedicated box
        // rather than the PHI-audited `MiniCoachBox`.
        AICoachSettingsBox.shared.clearStore(for: self)

        // 8. LOGOUT-NOTIF — purge delivered + pending local notifications and
        // reset the app-icon badge. PHI-adjacent: a delivered med reminder on
        // the lock screen reveals medication use, the badge count reveals
        // pending doses, and a pending scheduled reminder would fire under the
        // next user on a shared device. Purely local + network-independent, so
        // it always runs here at the tail of the cascade regardless of why the
        // session ended. The seam defaults to
        // `NotificationService.clearAllNotificationsOnLogout()` (idempotent /
        // safe when nothing is scheduled); the per-medication SpeziScheduler
        // task bookkeeping is reconciled separately in
        // `MedicationsStore.clearOnLogout()` above so the two stay consistent.
        await notificationClearOnLogoutHook?()
    }

    /// **06-05 — registered owned-task drains.** Awaits every cancel-and-drain
    /// seam a store family exposes for its retained authenticated tasks. New
    /// producers that retain authenticated work MUST register their drain here
    /// (the Dashboard/Settings/Medications/Labs/Documents families fence and
    /// discard instead of retaining, so measurements is currently the only
    /// registered owner). Idempotent — draining an idle store is a no-op.
    func drainAuthenticatedSessionWork() async {
        await measurementsStore.cancelAndDrainAuthenticatedWork()
    }

    /// Back-compat shim — kept for callers/tests that drive the switch-server
    /// CASCADE directly. The full production switch-server path is
    /// ``switchServer(to:)`` below; this shim forwards to
    /// `performFullLocalLogout(reason: .switchServer)` only.
    func handleLocalLogout() async {
        await performFullLocalLogout(reason: .switchServer)
    }

    /// **06-05 — the sole switch-server terminal path.** Stages `url`, holds
    /// the 06-10 account boundary for the whole operation, completes the old
    /// session's invalidate → drain → cleanup cascade FIRST, then wipes the
    /// old session's credentials, only then commits the persisted/runtime
    /// server mutation, and finally re-opens pairing. A replacement admission
    /// (or same-owner re-login) cannot race any part of the teardown because
    /// authentication transitions queue on the same boundary until this
    /// operation releases it.
    ///
    /// Failure semantics: `AppEnvironment.setCustomBaseURL` throwing after the
    /// teardown leaves the device signed out against the OLD server (tokens
    /// wiped, caches cleared) — fail-closed; the caller surfaces the error and
    /// the user can retry the switch or sign in again.
    func switchServer(to url: URL) async throws {
        guard await authStore.beginAuthenticationTransition() else { return }
        defer { authStore.finishAuthenticationTransition() }

        // Old-session teardown: invalidate shared lease, drain owned tasks,
        // then the reason-specific cleanup cascade (outbox + cipher key +
        // standalone mirror die with the server context — see LogoutReason).
        await performFullLocalLogout(reason: .switchServer)

        // Credentials of the old session (still-applicable per switch-server
        // rules). Deliberately NO `/api/auth/logout` round-trip — the revoke
        // would hit the NEW host with the OLD refresh token and either fail or
        // contaminate the new server's audit log. Matches the key set
        // `AuthService.logout()` removes locally.
        for key in [
            KeychainKey.authToken,
            KeychainKey.refreshToken,
            KeychainKey.refreshTokenExpiresAt,
            KeychainKey.accessTokenExpiresAt,
            KeychainKey.userID,
            // v0.8.0 W9 L-1 — the cold-launch display-name hint moves with
            // `userID` so the previous account's name never paints against
            // the next server.
            KeychainKey.userDisplayName,
            KeychainKey.deviceID
        ] {
            try? keychain.remove(forKey: key)
        }

        // Commit the server replacement only after the old session is
        // quiescent and stripped, then publish readmission.
        try AppEnvironment.setCustomBaseURL(url, keychain: keychain)
        await reloadEnvironment()
        authStore.beginServerPairing()
    }

    /// **v0.5.7 G.5** — Coach chat transcript hygiene on logout /
    /// 401 / account-deletion.
    ///
    /// By the time this runs the keychain `userID` has already been
    /// removed (`AuthStore.handleUnauthorized` / `auth.logout` /
    /// `auth.deleteAccount` precede every cleanup hook), so we can't
    /// resolve the previous partition via the store's
    /// `userIDProvider`. Wipe **every** partition in the chat
    /// persistence store — there is only one signed-in user with a
    /// transcript on the device at any time, and the standalone
    /// sentinel is the only other partition. Then drop the cached
    /// conversation store so the next AskCoach open re-hydrates
    /// against the new partition.
    ///
    /// Skips entirely when neither the conversation store nor the
    /// chat persistence layer was ever resolved this session
    /// (cold-launch with no AskCoach open).
    func wipeCoachChatOnLogout() {
        if let coachChatPersistence = LocalLLMBox.shared.chatStore(for: self) {
            coachChatPersistence.clearAll()
        }
        if let coachStore = LocalLLMBox.shared.store(for: self) {
            // Clear the in-memory chat too — even though we're about
            // to drop the cached store, a SwiftUI re-paint between
            // the logout and the cache-drop would otherwise flash
            // the previous user's transcript.
            coachStore.clearOnLogout(partition: nil)
        }
        LocalLLMBox.shared.clearStores(for: self)
    }
}
