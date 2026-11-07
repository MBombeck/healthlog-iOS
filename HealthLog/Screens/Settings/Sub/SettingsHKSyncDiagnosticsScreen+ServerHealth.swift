import SwiftUI

// MARK: - CU-21 (C1) — Server-Sicht auf die Sync-Gesundheit

/// Ableitung aus `GET /api/integrations/healthkit`, die die Diagnostikfläche
/// rendert.
///
/// **Zweck der Einheit, nicht Beiwerk:** der eigentliche Beweis für #66 ist
/// mehrtägig auf dem Gerät — der Operator trägt das iPhone normal und will nach
/// zwei bis drei Tagen ablesen können, ob der Server auch `background` bzw.
/// `push` gesehen hat. ``autonomy`` beantwortet genau das in einer Zeile, damit
/// niemand die Web-Oberfläche danebenlegen muss.
///
/// `internal` (nicht `private`), damit `HKServerSyncHealthSummaryTests` den
/// Vertrag pinnen kann, ohne gegen lokalisierten Text zu assertieren — gleiches
/// Muster wie ``KindRow``.
struct HKServerSyncHealthSummary: Equatable {
    /// #139 — the server's unified state. When present it is the only source
    /// of the verdict row; ``verdict`` (legacy `syncHealth`) answers only for a
    /// server without it.
    let health: ConnectionHealth?
    let verdict: SyncHealthVerdict?
    let since: Date?
    let lastSyncTrigger: String?
    let lastBackgroundSyncAt: Date?
    /// `nil` = Server kennt das Feld nicht; `[]` = kennt es, aber noch kein Typ
    /// hat geliefert.
    let freshness: [MetricFreshness]?

    init(config: HealthKitSyncConfig) {
        health = config.health
        verdict = config.health == nil ? config.syncHealth?.verdict : nil
        since = config.health.map(\.since) ?? config.syncHealth?.since
        lastSyncTrigger = config.lastSyncTrigger
        lastBackgroundSyncAt = config.lastBackgroundSyncAt
        freshness = config.metricFreshness
    }

    init(
        verdict: SyncHealthVerdict?,
        since: Date? = nil,
        lastSyncTrigger: String? = nil,
        lastBackgroundSyncAt: Date? = nil,
        freshness: [MetricFreshness]? = nil,
        health: ConnectionHealth? = nil
    ) {
        self.health = health
        self.verdict = verdict
        self.since = since
        self.lastSyncTrigger = lastSyncTrigger
        self.lastBackgroundSyncAt = lastBackgroundSyncAt
        self.freshness = freshness
    }

    /// Die Frage, für die diese Einheit existiert: liefert dieses Telefon auch
    /// ohne geöffnete App?
    enum Autonomy: Equatable {
        /// Belegt — der Server hat einen Hintergrund- oder Push-Sweep gesehen.
        case confirmed
        /// Der Server hat bisher **nur** Vordergrund-Sweeps gesehen. Das ist
        /// die ehrliche Negativ-Antwort, kein Fehlerzustand: solange die
        /// mehrtägige Beobachtung läuft, kann das schlicht „noch nicht
        /// passiert" heißen.
        case foregroundOnly
        /// Der Server sagt nichts dazu (noch kein Sweep angekommen, oder
        /// älterer Server ohne das Feld).
        case unknown
    }

    var autonomy: Autonomy {
        // Ein Hintergrund-Zeitstempel ist der härteste Beleg — er überlebt auch
        // den Fall, dass der zuletzt gesehene Sweep zufällig ein
        // Vordergrund-Pull war.
        if lastBackgroundSyncAt != nil { return .confirmed }
        guard let raw = lastSyncTrigger, let kind = SyncTrigger(rawValue: raw) else {
            return .unknown
        }
        switch kind {
        case .background, .push: return .confirmed
        // V1 — "Sync all" is a person at the phone, not a phone that delivers alone.
        case .foreground, .manual: return .foregroundOnly
        // X4 — a history catch-up says nothing about who delivers; the
        // server never stores it as the last trigger either.
        case .backfill: return .unknown
        }
    }

    /// `false`, wenn der Server zu keinem der vier Felder etwas gesagt hat —
    /// dann zeigt die Fläche eine ehrliche „noch keine Server-Daten"-Zeile statt
    /// vier Gedankenstrichen.
    var hasServerData: Bool {
        health != nil || verdict != nil || lastSyncTrigger != nil || lastBackgroundSyncAt != nil || freshness != nil
    }

    // MARK: - Labels

    var autonomyLabel: String {
        switch autonomy {
        case .confirmed: String(localized: "settings.hkdiag.server_autonomy_yes")
        case .foregroundOnly: String(localized: "settings.hkdiag.server_autonomy_no")
        case .unknown: String(localized: "settings.hkdiag.server_autonomy_unknown")
        }
    }

    var autonomyTint: Color {
        switch autonomy {
        case .confirmed: HLColor.statusOK
        case .foregroundOnly: HLColor.statusWarn
        case .unknown: HLText.tertiary
        }
    }

    var verdictLabel: String {
        if let health { return ConnectionHealthPresentation(health: health).stateLabel }
        guard let verdict else { return String(localized: "settings.hkdiag.never") }
        switch verdict {
        case .fresh: return String(localized: "settings.hkdiag.verdict_fresh")
        case .stale: return String(localized: "settings.hkdiag.verdict_stale")
        case .stalled: return String(localized: "settings.hkdiag.verdict_stalled")
        case .failing: return String(localized: "settings.hkdiag.verdict_failing")
        case .reauthRequired: return String(localized: "settings.hkdiag.verdict_reauth_required")
        case .parked: return String(localized: "settings.hkdiag.verdict_parked")
        case .pendingFirstSync: return String(localized: "settings.hkdiag.verdict_pending_first_sync")
        case .disconnected: return String(localized: "settings.hkdiag.verdict_disconnected")
        case .unknown:
            // K1 — ein neues Server-Wort ist ein Bezeichner, kein Satz. Es wird
            // neutral „Unbekannt" gelesen (und nicht rot gefärbt, siehe
            // `verdictTint`), statt als Rohwert im UI zu stehen.
            return HKSyncDiagnosticsVocabulary.unknown
        }
    }

    var verdictTint: Color {
        if let health {
            return ConnectionHealthPresentation(health: health).needsAttention ? HLColor.statusWarn : HLText.secondary
        }
        guard let verdict else { return HLText.tertiary }
        return verdict.needsAttention ? HLColor.statusWarn : HLText.secondary
    }

    /// Lokalisiertes Wort für den zuletzt gesehenen Auslöser; ein unbekanntes
    /// Server-Wort liest sich neutral „Unbekannt" (K1).
    var triggerLabel: String {
        guard let raw = lastSyncTrigger else {
            return String(localized: "settings.hkdiag.never")
        }
        switch SyncTrigger(rawValue: raw) {
        case .foreground: return String(localized: "settings.hkdiag.trigger_foreground")
        case .background: return String(localized: "settings.hkdiag.trigger_background")
        case .push: return String(localized: "settings.hkdiag.trigger_push")
        case .manual: return HKSyncDiagnosticsVocabulary.collectionTrigger("manual")
        case .backfill, nil: return HKSyncDiagnosticsVocabulary.unknown
        }
    }
}

// MARK: - Card

extension SettingsHKSyncDiagnosticsScreen {
    /// Server-Sicht: Urteil, Auslöser, Hintergrund-Beleg, Frische pro Typ.
    var serverHealthCard: some View {
        // 1.4 B2-c — the reading guide ("a missing type never delivered, it
        // is not zero") and the legend of the times are in the (i).
        HLSettingsCard(
            icon: "antenna.radiowaves.left.and.right",
            title: "settings.hkdiag.server_title"
        ) {
            if let summary = serverSummary {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if summary.hasServerData {
                        serverStatRow(
                            label: "settings.hkdiag.server_autonomy",
                            value: summary.autonomyLabel,
                            tint: summary.autonomyTint
                        )
                        // W5 (#126 1.4) — right under the answer it proves:
                        // opening the app moves the last trigger, never this.
                        serverStatRow(
                            label: "settings.hkdiag.server_last_background",
                            value: relativeOrNever(summary.lastBackgroundSyncAt),
                            tint: HLText.secondary
                        )
                        serverStatRow(
                            label: "settings.hkdiag.server_verdict",
                            value: summary.verdictLabel,
                            tint: summary.verdictTint
                        )
                        // #139 — the reason behind the verdict, one sentence.
                        if let health = summary.health, ConnectionHealthPresentation(health: health).showsDetail {
                            Text(verbatim: ConnectionHealthPresentation(health: health).sentence)
                                .font(.hlCaption)
                                .foregroundStyle(HLText.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let since = summary.since {
                            serverStatRow(
                                label: "settings.hkdiag.server_since",
                                value: since.formatted(.relative(presentation: .named)),
                                tint: HLText.secondary
                            )
                        }
                        serverStatRow(
                            label: "settings.hkdiag.server_trigger",
                            value: summary.triggerLabel,
                            tint: HLText.secondary
                        )
                        freshnessSection(summary.freshness)
                    } else {
                        Text("settings.hkdiag.server_no_data")
                            .font(.hlBody)
                            .foregroundStyle(HLText.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if serverLoadFailed {
                Text("settings.hkdiag.server_unavailable")
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, HLSpace.sm)
            }
        }
    }

    /// Frische pro Typ. Ein Typ, den der Server nicht nennt, ist **abwesend** —
    /// er wird nicht als Null-Zeile gezeichnet, sondern gar nicht. Der
    /// Karten-Footer erklärt das, damit die Lücke nicht als Fehler gelesen wird.
    @ViewBuilder
    private func freshnessSection(_ freshness: [MetricFreshness]?) -> some View {
        if let freshness {
            Divider().opacity(0.4)
            Text("settings.hkdiag.freshness_title")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            if freshness.isEmpty {
                Text("settings.hkdiag.freshness_empty")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(freshness) { row in
                    ServerFreshnessRow(row: row, seenText: relativeOrNever(row.lastSeenAt))
                }
            }
        }
    }

    /// 1.4 B4 — the screen's one stat row: wraps in full, stacks at the
    /// accessibility sizes (it was cut after two lines).
    private func serverStatRow(label: LocalizedStringKey, value: String, tint: Color) -> some View {
        HLSettingsStatRow(label: Text(label), value: value, tint: tint)
    }

    /// Holt `GET /api/integrations/healthkit` frisch (nicht aus dem SWR-Cache
    /// des Settings-Stores): eine Diagnostikfläche über Frische darf keine
    /// stundenalte Antwort zeigen. Fehler bleiben still — die Karte sagt dann
    /// „nicht erreichbar" statt zu behaupten, es gäbe keine Hintergrund-Syncs.
    func loadServerSyncHealth() async {
        guard let repo = container?.settingsRepo else {
            serverLoadFailed = true
            return
        }
        do {
            let config = try await repo.healthKitConfig()
            serverSummary = HKServerSyncHealthSummary(config: config)
            serverLoadFailed = false
        } catch {
            serverLoadFailed = true
            HLLog.healthKit
                .info("Sync-Diagnose: Server-Sync-Gesundheit nicht abrufbar: \(error.localizedDescription, privacy: .public)")
        }
    }
}
