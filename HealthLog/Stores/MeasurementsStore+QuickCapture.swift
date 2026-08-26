import Foundation

// MARK: - Manual capture (phone MeasureSheet + watch quick-capture)

public extension MeasurementsStore {
    /// Capture a manually-entered measurement (optimistic insert → server
    /// write → HK mirror → rollback-on-failure). The Bool-returning façade over
    /// ``captureReturningOutcome(kind:value:note:glucoseContext:)``.
    ///
    /// Contract (UNCHANGED — the `MeasureSheet` + banner depend on it): `true`
    /// **only** when the server write committed (`.success`). A retriable
    /// offline failure that durably enqueues to the Outbox (`.queued`) returns
    /// `false` — the row stands locally and the banner surfaces the deferred
    /// state, but the write hasn't COMMITTED, so the sheet shouldn't claim
    /// success. `.failed` (rolled back) also returns `false`. The watch
    /// quick-capture path uses `captureReturningOutcome` directly so it can ack
    /// the wrist with the finer saved / will-sync / not-saved distinction.
    ///
    /// Build 1 / item 1.4b — `recordedAt` is now a parameter (defaulting to
    /// `.now`, so the watch quick-capture and every other existing caller are
    /// unchanged). The phone's Erfassen sheet passes an operator-chosen instant
    /// so a past reading can be logged directly instead of via save-then-edit.
    func capture(
        kind: MetricKind,
        value: MeasurementValue,
        note: String?,
        glucoseContext: GlucoseContext? = nil,
        recordedAt: Date = .now
    ) async -> Bool {
        await captureReturningOutcome(
            kind: kind, value: value, note: note, glucoseContext: glucoseContext, recordedAt: recordedAt
        ) == .success
    }

    /// Outcome-returning variant of ``capture(kind:value:note:glucoseContext:)``.
    /// Single source of truth for the optimistic-insert / repo-call / HK-mirror
    /// / rollback dance; `capture` is the Bool-returning façade. The watch
    /// companion routes its quick-capture through here so it can ack the wrist
    /// with the honest saved / will-sync / not-saved state (mirrors
    /// `MoodStore.logReturningOutcome`).
    func captureReturningOutcome(
        kind: MetricKind,
        value: MeasurementValue,
        note: String?,
        glucoseContext: GlucoseContext? = nil,
        recordedAt: Date = .now
    ) async -> MedicationsStore.WriteOutcome {
        guard let lease = captureAuthenticatedSessionLease() else { return .failed(.canceled) }
        // T-2: glucose-context only meaningful when kind == .glucose. We
        // accept the param unconditionally so call-sites don't need a
        // kind-switch, but discard it for non-glucose so a future widening
        // of the picker UI (e.g. weight-context) can't accidentally
        // contaminate other kinds' wire bodies.
        let effectiveContext: GlucoseContext? = kind == .glucose ? glucoseContext : nil
        let local = Measurement(
            id: "local-\(UUID().uuidString)",
            kind: kind,
            // Item 1.4b — was hard-coded `.now`, which made backdating
            // impossible from the capture sheet.
            recordedAt: recordedAt,
            value: value,
            note: note,
            source: .manual,
            glucoseContext: effectiveContext
        )
        // audit-v0162 H-3 — bump so an in-flight `.fresh` (fetched before this
        // capture) can't drop the just-inserted optimistic row.
        bumpMutationGeneration()
        // Item 1.4b — `recent` is newest-first. A backdated capture must land at
        // its chronological position, not unconditionally at the top, or the
        // optimistic row claims to be the latest reading until the next load.
        insertChronologically(local)
        do {
            try lease.requireCurrent()
            let saved = try await repo.create(local)
            try lease.requireCurrent()
            // A360-5 H-1 — survive a concurrent `load()` that replaced `recent`
            // during the `await repo.create`. If the optimistic temp row is
            // gone, the server-saved row would otherwise vanish from the cache
            // (it exists on the server but not the list until a full reload).
            // Reconcile in three steps:
            //   1. temp row still present → swap in the server row (happy path),
            //   2. server row already pulled in by the concurrent load → no-op
            //      (avoid a duplicate),
            //   3. neither present → re-insert the saved row at the top so the
            //      capture is never silently dropped.
            if let i = recent.firstIndex(where: { $0.id == local.id }) {
                recent[i] = saved
            } else if !recent.contains(where: { $0.id == saved.id }) {
                insertChronologically(saved)
            }
            // Spiegel an HealthKit (Anti-Duplikat via ExternalUUID). HK ist ein
            // sekundärer Mirror — ein Fehler darf den Server-Write nicht
            // zurückrollen, aber wird geloggt (kein Silent-Swallow, PROJECT_GUIDE.md).
            //
            // v0.14 RISK-1 (dedup option B): im Standalone-/Offline-Modus den
            // HK-Mirror-Write UNTERDRÜCKEN. Die manuelle Messung wird beim
            // späteren Pair als `MANUAL` hochgeladen; schrieben wir sie auch nach
            // HK, läse der HK-Observer sie beim Pair erneut als `APPLE_HEALTH`
            // ein → Duplikat derselben physischen Messung. Ohne Mirror bleibt
            // genau eine Zeile (der MANUAL-Upload). Im paired Modus spiegelt der
            // manuelle Write WIE BISHER nach HK (Anti-Duplikat-Logik unberührt).
            if isStandalone?() == true {
                HLLog.healthKit
                    .debug("HK-Mirror write (measurement) im Standalone-Modus übersprungen (Dedup Option B)")
            } else {
                do {
                    try lease.requireCurrent()
                    try await healthKit?.write(saved)
                    try lease.requireCurrent()
                } catch {
                    guard authenticatedEffectIsCurrent(lease) else { return .failed(.canceled) }
                    HLLog.healthKit
                        .warning("HK-Mirror write (measurement) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard authenticatedEffectIsCurrent(lease) else { return .failed(.canceled) }
            // RECONCILE-CELEBRATE: PR-detection runs against the snapshot
            // BEFORE this commit landed (so we compare against the prior
            // bucket leader, not against ourselves). Fires off the main
            // thread of the capture call so a slow celebration scheduler
            // can never block the commit-return path; the coordinator
            // itself is @MainActor so the publish hops back implicitly.
            detectAndPublishPersonalRecord(for: saved)
            return .success
        } catch let err as HLError {
            guard authenticatedEffectIsCurrent(lease) else { return .failed(.canceled) }
            error = err
            // Hat der Repository die Outbox enqueued (retriable ODER ein
            // transient-refresh 401 → `shouldPersistToOutbox`), bleibt der
            // lokale Eintrag sichtbar bis zum Replay. Nur bei wirklich
            // verworfenen Writes Rollback (Spec §3 — "optimistisch, mit
            // Rollback bei Fehler"). Ein 401 mid-write wird durabel
            // enqueued — kein Rollback, sonst "ich hab's geloggt, jetzt weg".
            if !err.shouldPersistToOutbox {
                recent.removeAll { $0.id == local.id }
                return .failed(err)
            }
            // Durably enqueued in the Outbox — the local row stands and will
            // replay; report `.queued` so the watch shows "will sync."
            return .queued
        } catch {
            guard authenticatedEffectIsCurrent(lease) else { return .failed(.canceled) }
            let wrapped = HLError.unknown(String(describing: error))
            self.error = wrapped
            recent.removeAll { $0.id == local.id }
            return .failed(wrapped)
        }
    }

    /// Insert into the newest-first ``recent`` list at the position `recordedAt`
    /// warrants. Degenerates to `insert(at: 0)` for a `.now` capture, which is
    /// every pre-item-1.4b call site.
    private func insertChronologically(_ measurement: Measurement) {
        let index = recent.firstIndex { $0.recordedAt <= measurement.recordedAt } ?? recent.endIndex
        recent.insert(measurement, at: index)
    }
}
