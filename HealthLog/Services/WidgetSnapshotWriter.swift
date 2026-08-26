import Foundation
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// **v0.8.4 WWIDGET-2 — writes the medication widget snapshot + kicks the
/// widget timeline reload.**
///
/// App-only (the extension never writes). Pulls the current medication +
/// today's-intakes arrays off `MedicationsStore`, maps them to the tiny
/// shared ``WidgetSnapshot`` (via the pure ``WidgetSnapshot/make(medications:serverIntakes:now:calendar:)``),
/// persists it into the App Group container, then asks WidgetKit to rebuild
/// the next-dose + compliance timelines so the Home / Lock-Screen widgets
/// reflect the change.
///
/// Wired onto `MedicationsStore.onIntakesDidChange` (see
/// `AppContainer+Widgets.swift`) — the same single-slot callback the badge
/// + Live-Activity reconcile chain onto — so every load / mark / snooze /
/// synth-create that moves the schedule or the taken-count refreshes the
/// widgets. A failed write is logged and swallowed: a widget hiccup must
/// never break a medication mark.
@MainActor
public struct WidgetSnapshotWriter {
    /// **Phase 09 Wave 0** — the timeline-reload seam. `WidgetCenter` is
    /// invisible to a unit test, which is why "an unchanged value must not burn
    /// a reload" has never been assertable; Plan 09-03 needs exactly that. The
    /// live default is WidgetKit, so production behaviour is unchanged.
    private let reloader: WidgetTimelineReloader
    /// **Phase 09 / plan 09-03** — the one shared admission + sequencing facade.
    ///
    /// This type is a `struct` on purpose (a source guard from 09-01 pins that,
    /// and every call site copies it into a store callback), so the state that
    /// has to be *shared* between those copies — the operation tail, the account
    /// epoch, whether the writer is admitting work at all — lives behind this
    /// one reference. Copying a `WidgetSnapshotWriter` copies a pointer to the
    /// same sequencer; there is exactly one queue per writer, never one per
    /// callback.
    private let sequencer: WidgetWriteSequencer
    /// The one app-side read/modify/encode/write boundary (09-03). Shared with
    /// ``sequencer`` by construction — one boundary per writer.
    private let persistence: WidgetSnapshotPersistence

    public init(
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        reloader: WidgetTimelineReloader = .live
    ) {
        self.reloader = reloader
        let boundary = WidgetSnapshotPersistence(store: store)
        persistence = boundary
        sequencer = WidgetWriteSequencer(persistence: boundary)
    }

    /// Build + persist the snapshot from the live store, then reload the
    /// widget timelines. Synchronous map (the arrays are small — < 20 meds,
    /// < 10 intakes), `try?`-guarded file write, fire-and-forget reload.
    ///
    /// `derivedIntakes` is the store's `derivedTodayIntakes` (server-emitted
    /// unioned with synthesised placeholders) so the widget's compliance +
    /// next-dose agree with the in-app surfaces.
    ///
    /// `serverCompliancePercent` is the SERVER ledger adherence value the
    /// in-app card/`LedgerHistorySection` paint (aggregated across active meds
    /// by the caller from the store's `complianceCardSnapshots`); the ring arc
    /// tracks it so the widget never recomputes a divergent number. `nil` when
    /// the server value hasn't loaded — the ring then falls back to the
    /// today-count fraction.
    public func refresh(
        medications: [Medication],
        derivedIntakes: [MedicationIntake],
        serverCompliancePercent: Int? = nil,
        now: Date = .now
    ) {
        // **09-03 — the value is snapshotted here, the file is touched there.**
        // The pure map runs at the callback, where the (small: < 20 meds,
        // < 10 intakes) arrays already are, and where `HLTimeFormat.current()`
        // legitimately reads the app's own `.standard` mirror. `recentMood` is a
        // pass-through in `make`, so leaving it `nil` here and filling it from
        // the on-disk snapshot inside the boundary is the same value — read
        // against the snapshot the write will actually land on top of.
        let mapped = WidgetSnapshot.make(
            medications: medications,
            derivedIntakes: derivedIntakes,
            serverCompliancePercent: serverCompliancePercent,
            // W-B183 — the app's resolved time-format, so the widget renders
            // dose times with the same clock (the widget process can't see it).
            timeFormatRaw: HLTimeFormat.current().rawValue,
            now: now
        )
        enqueueWrite(failureNote: "widget-snapshot write failed") { current in
            // v0.15 companion-#3 — the med path owns dose + compliance and
            // carries mood / score / latest measurement through unchanged.
            let snapshot = WidgetSnapshot(
                nextDose: mapped.nextDose,
                compliance: mapped.compliance,
                recentMood: current?.recentMood,
                healthScore: current?.healthScore,
                latestMeasurement: current?.latestMeasurement,
                timeFormatRaw: mapped.timeFormatRaw,
                generatedAt: mapped.generatedAt
            )
            // v0.12 W8-7 — diff before reload. `onIntakesDidChange` fires on
            // every store load (incl. idempotent revalidations that return
            // identical data); `generatedAt` always differs, so only the
            // widget-bearing fields are compared. Byte-identical → skip the
            // write AND the per-kind reload, so a no-op burns neither the
            // per-day reload budget nor extension wake energy.
            let doseChanged = current?.nextDose != snapshot.nextDose
            let complianceChanged = current?.compliance != snapshot.compliance
            guard current == nil || doseChanged || complianceChanged else { return .skip }
            // First write (current == nil) reloads both kinds; otherwise only
            // the timeline whose data actually moved.
            guard current != nil else {
                return .write(snapshot, reloadKinds: [WidgetKind.nextDose, WidgetKind.compliance])
            }
            var kinds: [String] = []
            if doseChanged { kinds.append(WidgetKind.nextDose) }
            if complianceChanged { kinds.append(WidgetKind.compliance) }
            return .write(snapshot, reloadKinds: kinds)
        }
    }

    /// **v0.10.0 W-Mood-B** — update only the mood glance, preserving the
    /// medication fields the med refresh path owns. Called when the mood
    /// store's entries change (see `AppContainer+Widgets`). Re-reads the
    /// current snapshot so a concurrent med write isn't clobbered.
    public func refreshMood(recentMood: WidgetSnapshot.RecentMood?, now: Date = .now) {
        enqueueWrite(failureNote: "widget-snapshot mood write failed") { snapshot in
            let current = snapshot ?? .placeholder
            // v0.12 W8-7 — skip the mood-timeline reload when the glance is
            // unchanged (the mood store fires `onEntriesDidChange` on every load).
            guard current.recentMood != recentMood else { return .skip }
            return .write(
                WidgetSnapshot(
                    nextDose: current.nextDose,
                    compliance: current.compliance,
                    recentMood: recentMood,
                    // v0.15 companion-#3 — preserve the score + latest-measurement
                    // glances (owned by their own paths) on a mood-only write.
                    healthScore: current.healthScore,
                    latestMeasurement: current.latestMeasurement,
                    // Preserve the med-refresh-owned time-format so a mood-only
                    // write doesn't reset the widget's clock to AUTO.
                    timeFormatRaw: current.timeFormatRaw,
                    generatedAt: now
                ),
                reloadKinds: [WidgetKind.mood]
            )
        }
    }

    /// **v0.15 companion-#3** — update only the Personal Health Score glance,
    /// preserving the med + mood + measurement fields the other refresh paths
    /// own. Called when the dashboard score loads / changes (see
    /// `AppContainer+Widgets`). Diff-skips a no-op and reloads only the score
    /// timeline.
    public func refreshHealthScore(_ glance: WidgetSnapshot.HealthScoreGlance?, now: Date = .now) {
        enqueueWrite(failureNote: "widget-snapshot score write failed") { snapshot in
            let current = snapshot ?? .placeholder
            guard current.healthScore != glance else { return .skip }
            return .write(
                WidgetSnapshot(
                    nextDose: current.nextDose,
                    compliance: current.compliance,
                    recentMood: current.recentMood,
                    healthScore: glance,
                    latestMeasurement: current.latestMeasurement,
                    timeFormatRaw: current.timeFormatRaw,
                    generatedAt: now
                ),
                reloadKinds: [WidgetKind.healthScore]
            )
        }
    }

    /// **v0.15 companion-#3** — update only the latest-measurement glance,
    /// preserving the other fields. Called when the measurements list loads /
    /// changes (see `AppContainer+Widgets`). Diff-skips a no-op and reloads only
    /// the latest-measurement timeline.
    public func refreshLatestMeasurement(_ latest: WidgetSnapshot.LatestMeasurement?, now: Date = .now) {
        enqueueWrite(failureNote: "widget-snapshot measurement write failed") { snapshot in
            let current = snapshot ?? .placeholder
            guard current.latestMeasurement != latest else { return .skip }
            return .write(
                WidgetSnapshot(
                    nextDose: current.nextDose,
                    compliance: current.compliance,
                    recentMood: current.recentMood,
                    healthScore: current.healthScore,
                    latestMeasurement: latest,
                    timeFormatRaw: current.timeFormatRaw,
                    generatedAt: now
                ),
                reloadKinds: [WidgetKind.latestMeasurement]
            )
        }
    }

    /// Clear the snapshot back to the neutral placeholder on logout so the
    /// previous user's next dose / compliance / score / measurement never
    /// lingers on the Home / Lock-Screen widgets for the next user on a
    /// shared device. Reloads **every** widget kind so the widgets repaint
    /// their empty state.
    ///
    /// **W-PHI-HARDENING (reliability audit H4) — this is a hard shared-device
    /// PHI invariant, NOT a best-effort hint.** The snapshot file is the only
    /// at-rest widget PHI (med name + next-dose time + today's mood + score +
    /// latest reading), so a failed clear leaves the PREVIOUS user's medical
    /// data rendered on the Home / Lock Screen for whoever signs in next.
    /// Pre-hardening the clear was a silent `try?` — a failed App-Group write
    /// passed unnoticed and the leak shipped. Now the write failure is
    /// surfaced (`throws`) so the logout cascade logs it (no PHI), and the
    /// timeline reload fires **regardless** of the write outcome: even if the
    /// placeholder write failed, asking WidgetKit to rebuild gives the
    /// extension a chance to re-read (and on a corrupt/missing file the
    /// provider falls back to `.placeholder`), so a best-effort repaint to
    /// empty still happens. `reloadAllTimelines()` (not the per-kind list) so a
    /// future widget kind can never be silently skipped by this reset.
    ///
    /// **09-03 — the account boundary.** `reset()` closes admission and adopts
    /// the next account epoch *before* it awaits everything already queued, so
    /// an update that was enqueued by the signed-out account cannot land after
    /// the placeholder: it is either drained before the placeholder is written,
    /// or refused by the persistence boundary for carrying a retired epoch.
    /// Admission stays closed until ``admitNextAccount()`` — the next
    /// authenticated composition — re-opens it.
    public func reset() async throws {
        try await sequencer.reset { epoch in
            defer { reloadAllWidgetTimelines() }
            let token = HLPerfSignpost.open(.widgetPersist, magnitude: .small)
            var completed = false
            defer { HLPerfSignpost.close(token, completed: completed) }
            _ = try await persistence.apply(epoch: epoch) { _ in .write(.placeholder, reloadKinds: []) }
            completed = true
        }
    }

    /// Await every operation this writer has already accepted. Test seam and
    /// teardown helper — production drains through ``reset()``.
    public func drainPendingWrites() async {
        await sequencer.drain()
    }

    /// Re-open admission for the next authenticated composition. Called from the
    /// wiring that rebuilds the widget callbacks for a newly signed-in account.
    public func admitNextAccount() {
        sequencer.admitNextAccount()
    }

    private func reloadAllWidgetTimelines() {
        reloader.reloadAll()
    }

    /// **The one enqueue path.**
    ///
    /// Every refresh above appends here, and nothing else calls the persistence
    /// boundary: no free-standing `Task`, no direct `store.write`. The sequencer
    /// chains each operation behind the one that was at the tail when this ran,
    /// and appending happens synchronously on the main actor inside the store
    /// callback — so the write order is the callback order.
    ///
    /// A failed write is logged (no PHI) and swallowed, unchanged from before: a
    /// widget hiccup must never break a medication mark. Only ``reset()``
    /// propagates, because the logout clear is a hard PHI invariant.
    private func enqueueWrite(
        failureNote: StaticString,
        _ mutate: @escaping @Sendable (WidgetSnapshot?) -> WidgetSnapshotDecision
    ) {
        let boundary = persistence
        let reloader = reloader
        sequencer.enqueue { epoch in
            let token = HLPerfSignpost.open(.widgetPersist, magnitude: .small)
            var completed = false
            defer { HLPerfSignpost.close(token, completed: completed) }
            do {
                let kinds = try await boundary.apply(epoch: epoch, mutate)
                completed = true
                for kind in kinds {
                    reloader.reload(kind)
                }
            } catch {
                // `failureNote` is a `StaticString`, which os.Logger always
                // records publicly without a `privacy:` specifier — the four
                // call sites keep their distinct messages while the only value
                // carrying anything runtime stays behind `LogSanitizer.redact`.
                HLLog.storage.error(
                    "\(failureNote): \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }
}

/// **Phase 09 Wave 0 — the WidgetKit reload seam.**
///
/// `WidgetCenter.shared` reaches straight into the system from inside a
/// `@MainActor` struct, so from a test there is no way to tell a reload that
/// happened from one that was correctly skipped. That is the exact contract
/// Plan 09-03 has to prove ("unchanged values skip the reload", "logout reloads
/// every kind"), and it needs this indirection to exist first. The live default
/// is the same `WidgetCenter` call it replaced.
public struct WidgetTimelineReloader: Sendable {
    private let reloadKind: @Sendable (String) -> Void
    private let reloadEverything: @Sendable () -> Void

    public init(
        reload: @escaping @Sendable (String) -> Void,
        reloadAll: @escaping @Sendable () -> Void
    ) {
        reloadKind = reload
        reloadEverything = reloadAll
    }

    public func reload(_ kind: String) {
        reloadKind(kind)
    }

    public func reloadAll() {
        reloadEverything()
    }

    public static let live = WidgetTimelineReloader(
        reload: { kind in
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            #endif
        },
        reloadAll: {
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    )
}
