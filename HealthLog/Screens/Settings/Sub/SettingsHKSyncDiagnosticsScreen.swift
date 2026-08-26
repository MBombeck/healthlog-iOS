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
/// **Read-only, with no exception since 08-15** — the screen does not trigger
/// sync, exposes no reset button (logout-cleanup happens implicitly via
/// `HKSyncDiagnostics.reset()` when the auth store wipes) and can no longer
/// change what this device uploads. A "Jetzt syncen" affordance lives one
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
/// **Counters are session-scope** — they zero on cold launch. The
/// surface explains this explicitly so the operator doesn't mistake
/// "0 reads" for "sync broken" right after a restart.
struct SettingsHKSyncDiagnosticsScreen: View {
    @State var diagnostics = HKSyncDiagnostics.shared
    @Environment(HKReadinessStore.self) private var hkReadiness
    /// CU-21 (C1) — Zugriff auf `settingsRepo` für den frischen
    /// `GET /api/integrations/healthkit`. `internal`, damit die
    /// `+ServerHealth`-Extension (file_length-Disziplin) sie lesen kann.
    @Environment(\.appContainer) var container
    @State var serverSummary: HKServerSyncHealthSummary?
    @State var serverLoadFailed = false

    var body: some View {
        HLSettingsPage(title: "settings.hkdiag.title") {
            summaryCard
            // CU-21 — die Server-Sicht steht bewusst DIREKT unter der
            // Zusammenfassung: sie trägt die Antwort auf „liefert dieses
            // Telefon selbstständig?", die einzige Hintergrund-Aussage, die
            // ohne Log-Wissen lesbar ist.
            serverHealthCard
            workoutDeliveryCard
            kindListCard
            explainerCard
            systemLimitsCard
            supportDiagnosticsCard
        }
        .navigationTitle("settings.hkdiag.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await hkReadiness.refresh() }
        .task { await loadServerSyncHealth() }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        HLSettingsCard(
            icon: "waveform.path.ecg",
            title: "settings.hkdiag.summary_title",
            subtitle: "settings.hkdiag.summary_subtitle"
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
        HLSettingsCard(
            icon: "lifepreserver",
            title: "settings.support.title",
            footer: "settings.support.entry_footer"
        ) {
            HLSettingsActionRow(title: "settings.support.nav_row", presents: .push) {
                SettingsSupportDiagnosticsScreen(topic: .appleHealth)
            }
            .accessibilityIdentifier("settings.hkdiag.supportDiagnosticsEntry")
        }
    }

    // MARK: - System limits (#66 P0.1 — Baustein 4)

    /// Honest, localized note on the iOS system limits every background wake is
    /// subject to — so the operator does not read "Nie" as an app bug when it is
    /// really the OS withholding runtime.
    private var systemLimitsCard: some View {
        HLSettingsCard(
            icon: "exclamationmark.triangle",
            title: "settings.hkdiag.limits_title",
            footer: "settings.hkdiag.limits_footer"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bulletRow(
                    icon: "xmark.circle.fill",
                    text: "settings.hkdiag.limits_forcequit"
                )
                bulletRow(
                    icon: "switch.2",
                    text: "settings.hkdiag.limits_bgrefresh"
                )
                bulletRow(
                    icon: "clock.badge.questionmark",
                    text: "settings.hkdiag.limits_discretion"
                )
                // R4 — der Bullet nannte den Ort („in den iOS-Einstellungen"),
                // ohne hinzuführen. Der Satz sagt jetzt nur noch die Folge; der
                // Weg dorthin ist diese Zeile.
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
    }

    // MARK: - Per-Kind list

    private var kindListCard: some View {
        HLSettingsCard(
            icon: "list.bullet.indent",
            title: "settings.hkdiag.kinds_title",
            subtitle: "settings.hkdiag.kinds_subtitle"
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
                    .frame(width: 22, alignment: .center)
                Text(row.kind.descriptor.title)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                Spacer()
                Text(row.statusLabel)
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(row.statusTint)
            }
            HStack(spacing: HLSpace.md) {
                Text(row.detailLabel)
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(HLText.secondary)
                Spacer()
                Text(row.lastSeenLabel)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
        .padding(.vertical, HLSpace.xs)
    }

    // MARK: - Explainer

    private var explainerCard: some View {
        HLSettingsCard(
            icon: "info.circle",
            title: "settings.hkdiag.explainer_title"
        ) {
            // Audit-Gruppe 10 — der Karten-Footer („Diese Seite ist eine
            // Diagnose-Hilfe, kein Sync-Schalter. Synchronisation steuerst du
            // eine Ebene höher.") war ein Wegweiser ohne Ziel (R4). Ein
            // „Jetzt syncen" gehört laut IA-Entscheidung dieses Screens
            // ausdrücklich NICHT hierher (siehe Typ-Doku oben) — also fällt der
            // Satz ersatzlos, statt einen zweiten Auslöser zu bauen.
            //
            // Audit-Gruppe 9 — `explainer_session` sagte „Zähler sind
            // Sitzungs-bezogen" ein zweites Mal; die Heimat ist der
            // Karten-Untertitel über den Zählern (`summary_subtitle`), wo der
            // Nutzer die Zahlen liest.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                bulletRow(
                    icon: "arrow.down.circle.fill",
                    text: "settings.hkdiag.explainer_read"
                )
                bulletRow(
                    icon: "arrow.up.circle.fill",
                    text: "settings.hkdiag.explainer_upload"
                )
            }
        }
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

    private func bulletRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLText.secondary)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func statRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            Text(value)
                .font(.hlBody.monospacedDigit())
                .foregroundStyle(HLText.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
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
        return "\(when) · \(source)"
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
    private var rows: [KindRow] {
        let live = snapshot
        return Self.syncedKinds
            .map { kind in
                KindRow(kind: kind, stats: live[kind] ?? HKSyncDiagnostics.KindStats(identifier: kind.rawValue))
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.stats.lastObservationAt ?? lhs.stats.lastStatsActionAt
                let rhsDate = rhs.stats.lastObservationAt ?? rhs.stats.lastStatsActionAt
                switch (lhsDate, rhsDate) {
                case let (.some(l), .some(r)): return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return lhs.kind.rawValue < rhs.kind.rawValue
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
        /// A successful round-trip happened on EITHER path.
        case healthy
        /// No sign of life at all this session.
        case idle
        /// Reads happened, nothing uploaded on either path, last activity stale.
        case stalled
    }

    /// Classify against `now` (injectable for deterministic tests).
    func status(now: Date = Date()) -> Status {
        // Healthy when any successful round-trip happened on EITHER path —
        // crucially `statsActions > 0` rescues every cumulative kind whose
        // upload went up the HK-STATS path (the source of the old false
        // "Hängt").
        if stats.samplesUploadedTotal > 0 || statsActions > 0 || stats.lastAnchorAdvancedAt != nil {
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
        status() == .stalled ? HLColor.statusWarn : HLText.tertiary
    }

    /// Compact detail: "read 32 / up 30" plus optional stats counter for
    /// the cumulative path. Uses German short forms so the line fits one
    /// row at 320pt iPhone widths.
    var detailLabel: String {
        let read = stats.samplesReadTotal
        let uploaded = stats.samplesUploadedTotal
        let statsActions = stats.statsPostedTotal + stats.statsRepostedTotal
        if statsActions > 0 {
            return String(
                localized: "settings.hkdiag.detail_stats \(read) \(uploaded) \(statsActions)"
            )
        }
        return String(localized: "settings.hkdiag.detail_simple \(read) \(uploaded)")
    }

    var lastSeenLabel: String {
        let candidate = stats.lastObservationAt ?? stats.lastStatsActionAt
        guard let candidate else { return "—" }
        return candidate.formatted(.relative(presentation: .named))
    }
}

#Preview("SettingsHKSyncDiagnosticsScreen") {
    NavigationStack {
        SettingsHKSyncDiagnosticsScreen()
    }
}
