import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// `/settings/integrations/apple-health/diagnostics` — Sync-Diagnose.
///
/// Built for v0.5.4 BF-5 ("Apple Health lokale Daten werden nicht dargestellt").
/// Surfaces the per-`MetricKind` counters that
/// `HKSyncDiagnostics.shared` accumulates during the session: how many
/// foreign samples HK has handed us per kind, how many landed on the
/// server, when the last observation fired, when the anchor last
/// advanced. The operator (and any future debug session) can read this
/// inline instead of attaching to Console.app.
///
/// **Read-only except for two rows since #113 and W1** — the screen does not
/// trigger a sync and exposes no reset button (logout-cleanup happens
/// implicitly via `HKSyncDiagnostics.reset()` when the auth store wipes). One
/// action is "Resend skipped": it offers readings the server already refused
/// once more, the same rows, under the same account. The other (W1, 1.3.0) is
/// "Erneut senden" on the rows the outbox holds back: it re-arms rows already
/// queued and starts one replay pass. Neither can make the device send
/// anything new. A "Jetzt syncen" affordance lives one
/// screen up in Integrations → Apple Health; pushing the same button here
/// would be the wrong IA.
///
/// **08-15 — the switch and the wake counters are gone from here.** The
/// pulse-upload switch was the one control on this page that mutated what the
/// app sends to the server, and a Settings page that can make a phone start
/// manufacturing raw heart-rate uploads for diagnosis is not a release
/// surface; it is deleted, not relocated. The background wake timestamps are
/// not a mutation but they are not consumer copy either — "iOS woke us over
/// BGProcessing 40 minutes ago" answers a log reader's question — so they
/// moved behind the deliberate session in ``SettingsSupportDiagnosticsScreen``
/// together with the per-kind anchor advances.
///
/// **Counters are session-scope** — they zero on cold launch. The (i)
/// says so (1.4 B2-c), so "0 reads" right after a restart does not read as
/// "sync broken".
struct SettingsHKSyncDiagnosticsScreen: View {
    @State var diagnostics = HKSyncDiagnostics.shared
    @Environment(HKReadinessStore.self) private var hkReadiness
    /// CU-21 (C1) — Zugriff auf `settingsRepo` für den frischen
    /// `GET /api/integrations/healthkit`. `internal`, damit die
    /// `+ServerHealth`-Extension (file_length-Disziplin) sie lesen kann.
    @Environment(\.appContainer) var container
    @State var serverSummary: HKServerSyncHealthSummary?
    @State var serverLoadFailed = false
    /// #113 — the skip register of the signed-in account (`+Skipped`).
    @State var skippedSnapshot: HealthKitSkippedRowSnapshot?
    @State var resendSummary: HealthKitSkippedRowReoffer.Summary?
    @State var isResending = false
    /// #12 — the heart-rate bucket ledger of the signed-in account (`+HeartRateBuckets`).
    @State var hrBucketSnapshot: HRBucketDiagnosticsSnapshot?
    /// V1 — the persistent `stats:` upload record of the signed-in account (`+StatsUploads`).
    @State var statsUploadLog: HealthKitStatsUploadLog?
    /// W1 (1.3.0) — the outbox rows the replay holds back, by reason (`+HeldWrites`).
    @State var heldGroups: [OutboxHeldGroup] = []
    @State var isRearming = false
    @State var rearmedCount: Int?
    /// W5 (1.3.0) — "Bericht kopieren" just put the summary on the clipboard.
    @State var reportCopied = false

    var body: some View {
        HLSettingsPage(title: "settings.hkdiag.title") {
            // W5 (1.3.0, #126 1.4) — the server view comes first: it holds
            // the answer to "does this phone deliver on its own?" and the last
            // background arrival, which opening the app no longer hides. 1.4
            // B2-c: everything below is this iPhone; the (i) says which cards
            // count since the last launch and which are kept across launches.
            serverHealthCard
            // W1 — the banner's "waiting" count leaves these rows out, so this
            // is where they are explained.
            heldWritesCard
            summaryCard
            // V1 — the app's own half of the same question, per summed type,
            // kept across launches, with the server's line for the same type.
            statsUploadCard
            skippedCard
            heartRateBucketCard
            workoutDeliveryCard
            // 1.3 (#127) — how far back the older history has got, per type.
            historyPerTypeCard
            kindListCard
            backgroundCard
            reportCard
            supportDiagnosticsCard
        }
        .navigationTitle("settings.hkdiag.title")
        .navigationBarTitleDisplayMode(.inline)
        // 1.4 B2-c — the glossary is the screen's one (i): where each card's
        // values come from, what the words mean, the background limits. The
        // cards keep their titles and values.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HLInfoButton(content: info, accessibilityIdentifier: "settings.hkdiag.info")
            }
        }
        .task { await hkReadiness.refresh() }
        .task { await loadServerSyncHealth() }
        .task { await loadSkipped() }
        .task { loadHeartRateBuckets() }
        .task { loadStatsUploads() }
        .task { await loadHeldWrites() }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HLSettingsCard(
            icon: "waveform.path.ecg",
            title: "settings.hkdiag.summary_title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(
                    label: "settings.hkdiag.summary_kinds_observed",
                    value: "\(observedKindCount)"
                )
                statRow(
                    label: "settings.hkdiag.summary_samples_read",
                    value: "\(totalSamplesRead)"
                )
                statRow(
                    label: "settings.hkdiag.summary_samples_uploaded",
                    value: "\(totalSamplesUploaded)"
                )
                statRow(
                    label: "settings.hkdiag.summary_last_activity",
                    value: lastActivityLabel
                )
                // W-B182 — last active pull of the SpeziHealthKit manual
                // collectors. Distinguishes "never armed" (broken: shows
                // "Nie") from "armed, nothing new" (healthy: a recent trigger
                // with quiet kinds). Persisted, so it survives relaunch.
                statRow(
                    label: "settings.hkdiag.summary_last_trigger",
                    value: lastTriggerLabel
                )
            }
        }
    }

    // MARK: - Support session (08-15)

    /// **The way to the detail this page no longer carries.**
    ///
    /// The wake channels (#66 P0.1 — Baustein 4) and the per-kind anchor
    /// advances are the honest answer to "does this phone deliver on its own?"
    /// — but only for somebody who already knows what BGProcessing is. They now
    /// sit behind a two-step, view-local session; a plain push, because the
    /// gate belongs to the destination and starts locked on every mount.
    private var supportDiagnosticsCard: some View {
        // 1.4 B2-c — the next screen explains its own confirmation. 1.4 B4 —
        // one row, one heading: the row names its screen.
        HLSettingsCard {
            HLSettingsActionRow(title: "settings.support.title", presents: .push) {
                SettingsSupportDiagnosticsScreen(topic: .appleHealth)
            }
            .accessibilityIdentifier("settings.hkdiag.supportDiagnosticsEntry")
        }
    }

    // MARK: - Background (#66 P0.1 — Baustein 4)

    /// The way to the one iOS switch that decides whether background runs
    /// happen at all. 1.4 B2-c: the three limits and the "not an app bug"
    /// note are in the (i); the card keeps the action.
    private var backgroundCard: some View {
        HLSettingsCard(
            icon: "exclamationmark.triangle",
            title: "settings.hkdiag.limits_title"
        ) {
            HLSettingsActionRow(
                icon: "gear",
                title: "settings.hkdiag.limits_openIosSettings",
                presents: .external
            ) {
                openIOSSettings()
            }
            .accessibilityIdentifier("settings.hkdiag.openIosSettings")
        }
    }

    // MARK: - Per-Kind list

    private var kindListCard: some View {
        HLSettingsCard(
            icon: "list.bullet.indent",
            title: "settings.hkdiag.kinds_title"
        ) {
            if rows.isEmpty {
                Text("settings.hkdiag.kinds_empty")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    ForEach(rows, id: \.kind) { row in
                        kindRow(row)
                        if row.kind != rows.last?.kind {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private func kindRow(_ row: KindRow) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            HStack(spacing: HLSpace.md) {
                Image(systemName: row.kind.descriptor.sfSymbol)
                    .font(.hlIcon(HLIconSize.rowAction))
                    .foregroundStyle(HLText.primary)
                    .hlInfoIconColumn()
                Text(row.kind.descriptor.title)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(row.statusLabel)
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(row.statusTint)
            }
            if !row.isQuiet {
                Text(row.detailLabel)
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // W5 — says which time it is: checked, or a new value sent.
                Text(row.timeLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HLSpace.xs)
    }

    /// R4 — der Absprung, der den `limits_bgrefresh`-Wegweiser ersetzt.
    /// `openSettingsURLString` landet auf der HealthLog-Seite der
    /// iOS-Einstellungen; „Hintergrundaktualisierung" steht dort.
    private func openIOSSettings() {
        #if canImport(UIKit)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #endif
    }

    /// 1.4 B4 — label and value wrap in full (the workout counts ended in
    /// "47 nicht…" at the standard size) and stack at the accessibility sizes.
    func statRow(label: LocalizedStringKey, value: String) -> some View {
        HLSettingsStatRow(label: Text(label), value: value)
    }

    // MARK: - Derived state

    private var snapshot: [MetricKind: HKSyncDiagnostics.KindStats] {
        diagnostics.snapshotByKind()
    }

    private var observedKindCount: Int {
        snapshot.count
    }

    private var totalSamplesRead: Int {
        snapshot.values.reduce(0) { $0 + $1.samplesReadTotal }
    }

    private var totalSamplesUploaded: Int {
        snapshot.values.reduce(0) { $0 + $1.samplesUploadedTotal }
    }

    private var lastActivityLabel: String {
        guard let date = diagnostics.lastActivityAt else {
            return String(localized: "settings.hkdiag.never")
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// #66 P0.1 — a relative-time label for a wake timestamp, or the localized
    /// "Nie" when the channel has never fired. `internal` (not `private`) since
    /// CU-21 so the `+ServerHealth` extension file shares the one formatter.
    func relativeOrNever(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "settings.hkdiag.never")
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// W-B182 — "<relative time> · <source>" for the last manual-collector pull,
    /// or "Nie" when no trigger has ever run (the "never armed" tell).
    private var lastTriggerLabel: String {
        guard let date = diagnostics.lastCollectionTriggerAt else {
            return String(localized: "settings.hkdiag.never")
        }
        let when = date.formatted(.relative(presentation: .named))
        guard let source = diagnostics.lastCollectionTriggerSource else { return when }
        return "\(when), \(HKSyncDiagnosticsVocabulary.collectionTrigger(source))"
    }

    /// The full set of `MetricKind`s HealthLog syncs through the iOS HK
    /// observer path — seeded from the diagnostics reverse-map (which mirrors
    /// `HealthLogSampleTypeRegistry` 1:1). Kinds without a live `record(...)`
    /// event this session still appear with an "Idle/ausstehend" row, so the
    /// list reflects the REAL synced set instead of only what happened to fire
    /// in the current process (the cumulative cluster fires eagerly; vitals /
    /// sleep / mass / BP only on new observer samples → usually absent on a
    /// fresh launch). Computed once per render off a static set.
    private static let syncedKinds: [MetricKind] = Array(Set(HKSyncDiagnostics.identifierToKind.values))

    /// One UI row per synced `MetricKind`. Rows with recorded events use their
    /// live stats; the rest fall back to a zeroed placeholder so the full set
    /// is always visible. Sorted by most-recent activity first so the
    /// operator's eye lands on the active kinds, with idle kinds trailing
    /// stably by kind raw value.
    var rows: [KindRow] {
        let live = snapshot
        let summedKinds = Set(HealthKitCumulativeTypeConfig.defaults.compactMap {
            HKSyncDiagnostics.metricKind(for: $0.identifier)
        })
        let sweepAt = statsUploadLog?.lastSweep?.at
        return Self.syncedKinds
            .map { kind in
                KindRow(
                    kind: kind,
                    stats: live[kind] ?? HKSyncDiagnostics.KindStats(identifier: kind.rawValue),
                    registeredSkipCount: registeredSkips[kind] ?? 0,
                    lastSweepAt: summedKinds.contains(kind) ? sweepAt : nil
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.lastTouchedAt, rhs.lastTouchedAt) {
                case let (.some(l), .some(r)): l > r
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.kind.rawValue < rhs.kind.rawValue
                }
            }
    }
}

// MARK: - Row model

/// Internal (not `private`) so `SettingsHKSyncDiagnosticsStatusTests` can pin
/// the status-classification contract — specifically that a daily-stats kind
/// with stats actions > 0 is never flagged "Stalled".
struct KindRow: Equatable {
    let kind: MetricKind
    let stats: HKSyncDiagnostics.KindStats
    /// #113 — rows of this kind waiting in the skip register. Persistent, so the
    /// warning survives the cold-launch reset of the session counters.
    var registeredSkipCount: Int = 0
    /// W5 — for a summed kind, the last daily-statistics sweep (kept across
    /// launches): a check that found nothing new still counts as a check.
    var lastSweepAt: Date?

    /// Total HK-STATS aggregator actions (cumulative-kind path: Steps /
    /// Active Energy / Flights / Distance / Daylight). These flow over
    /// `HealthLogStatisticsSyncCoordinator`, NOT the per-sample batch route —
    /// so they bump `statsPosted/Patched/Reposted`, never `samplesUploaded`.
    private var statsActions: Int {
        stats.statsPostedTotal + stats.statsRepostedTotal
    }

    /// Most-recent proof-of-activity timestamp across BOTH sync paths. Used
    /// for the freshness-based stuck heuristic.
    private var lastActivityAt: Date? {
        [stats.lastAnchorAdvancedAt, stats.lastStatsActionAt, stats.lastObservationAt]
            .compactMap { $0 }
            .max()
    }

    /// A kind is only "stuck" when activity is genuinely STALE. The previous
    /// field-mismatch heuristic (`read > 0 && uploaded == 0`) false-flagged
    /// every cumulative kind: with `enableDailyStats` ON, the daily-stats gate
    /// drops the foreign cumulative samples after they're read, so `read > 0`
    /// while `uploaded == 0` — yet the REAL upload went up the stats path and
    /// bumped `statsPostedTotal` instead. Freshness can't lie like that.
    static let staleThreshold: TimeInterval = 6 * 60 * 60

    /// Classified sync-health, freed of the daily-stats false positive. The
    /// view derives both the label string and the warn-tint from this so the
    /// classification has exactly one home (and tests can pin it without
    /// asserting on localized text).
    enum Status: Equatable {
        /// #113 — rows of this kind were refused (skip register) or wait in the
        /// outbox. Outranks everything else: "OK" while readings are not
        /// stored is exactly the lie #113 was about.
        case warning
        /// A successful round-trip happened on EITHER path.
        case healthy
        /// No sign of life at all this session.
        case idle
        /// Reads happened, nothing uploaded on either path, last activity stale.
        case stalled
    }

    /// Classify against `now` (injectable for deterministic tests).
    func status(now: Date = Date()) -> Status {
        if stats.samplesSkippedTotal > 0 || stats.samplesParkedTotal > 0 || registeredSkipCount > 0 {
            return .warning
        }
        // Healthy when the server stored something on EITHER path —
        // crucially `statsActions > 0` rescues every cumulative kind whose
        // upload went up the HK-STATS path (the source of the old false
        // "Hängt").
        if stats.samplesUploadedTotal > 0 || statsActions > 0 {
            return .healthy
        }
        // #113 — an anchor move alone is no longer proof: a page whose every row
        // was refused moved it too. It counts only when nothing this path read
        // is unaccounted for — nothing read at all (armed, quiet), or every row
        // handed to the daily-statistics / HR-bucket path.
        if stats.lastAnchorAdvancedAt != nil, stats.samplesReadTotal == stats.samplesHandedOffTotal {
            return .healthy
        }
        if stats.samplesReadTotal == 0, statsActions == 0, stats.lastObservationAt == nil {
            return .idle
        }
        // Reads happened but nothing landed. Only call it stalled when activity
        // is genuinely STALE — a fresh read with an in-flight upload reads idle,
        // not alarming.
        if stats.samplesReadTotal > 0, stats.samplesUploadedTotal == 0,
           let last = lastActivityAt, now.timeIntervalSince(last) > Self.staleThreshold
        {
            return .stalled
        }
        return .idle
    }

    var statusLabel: String {
        switch status() {
        case .warning: String(localized: "settings.hkdiag.status_warn")
        case .healthy: String(localized: "settings.hkdiag.status_ok")
        case .idle: String(localized: "settings.hkdiag.status_idle")
        case .stalled: String(localized: "settings.hkdiag.status_stuck")
        }
    }

    var statusTint: Color {
        // v0.11 W-settings-typography minor: the genuine "stalled" state needs
        // the at-a-glance warn signal. Route through the semantic
        // `HLColor.statusWarn` token so a truly stalled sync reads as needing
        // attention. A daily-stats kind whose stats path is alive no longer
        // trips this.
        switch status() {
        case .stalled, .warning: HLColor.statusWarn
        case .healthy, .idle: HLText.tertiary
        }
    }

    /// Compact detail: "read 32 / up 30" plus optional stats counter for
    /// the cumulative path. Uses German short forms so the line fits one
    /// row at 320pt iPhone widths.
    var detailLabel: String {
        let read = stats.samplesReadTotal
        let uploaded = stats.samplesUploadedTotal
        let statsActions = stats.statsPostedTotal + stats.statsRepostedTotal
        let skipped = max(stats.samplesSkippedTotal, registeredSkipCount)
        if skipped > 0 || stats.samplesParkedTotal > 0 {
            return String(
                localized: "settings.hkdiag.detail_problems \(read) \(uploaded) \(skipped) \(stats.samplesParkedTotal)"
            )
        }
        if statsActions > 0 {
            return String(
                localized: "settings.hkdiag.detail_stats \(read) \(uploaded) \(statsActions)"
            )
        }
        return String(localized: "settings.hkdiag.detail_simple \(read) \(uploaded)")
    }
}

#Preview("SettingsHKSyncDiagnosticsScreen") {
    NavigationStack {
        SettingsHKSyncDiagnosticsScreen()
    }
}
