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
    let verdict: SyncHealthVerdict?
    let since: Date?
    let lastSyncTrigger: String?
    let lastBackgroundSyncAt: Date?
    /// `nil` = Server kennt das Feld nicht; `[]` = kennt es, aber noch kein Typ
    /// hat geliefert.
    let freshness: [MetricFreshness]?

    init(config: HealthKitSyncConfig) {
        verdict = config.syncHealth?.verdict
        since = config.syncHealth?.since
        lastSyncTrigger = config.lastSyncTrigger
        lastBackgroundSyncAt = config.lastBackgroundSyncAt
        freshness = config.metricFreshness
    }

    init(
        verdict: SyncHealthVerdict?,
        since: Date? = nil,
        lastSyncTrigger: String? = nil,
        lastBackgroundSyncAt: Date? = nil,
        freshness: [MetricFreshness]? = nil
    ) {
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
        case .foreground: return .foregroundOnly
        }
    }

    /// `false`, wenn der Server zu keinem der vier Felder etwas gesagt hat —
    /// dann zeigt die Fläche eine ehrliche „noch keine Server-Daten"-Zeile statt
    /// vier Gedankenstrichen.
    var hasServerData: Bool {
        verdict != nil || lastSyncTrigger != nil || lastBackgroundSyncAt != nil || freshness != nil
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
        case let .unknown(raw):
            // Ein neues Server-Wort wird wörtlich gezeigt statt verschwiegen.
            // Leerer Rohwert (Feld vorhanden, aber ohne `verdict`) fällt auf die
            // generische Unbekannt-Zeile zurück.
            return raw.isEmpty
                ? String(localized: "settings.hkdiag.verdict_unknown")
                : raw
        }
    }

    var verdictTint: Color {
        guard let verdict else { return HLText.tertiary }
        return verdict.needsAttention ? HLColor.statusWarn : HLText.secondary
    }

    /// Lokalisiertes Wort für den zuletzt gesehenen Auslöser; ein unbekanntes
    /// Server-Wort wird wörtlich durchgereicht.
    var triggerLabel: String {
        guard let raw = lastSyncTrigger else {
            return String(localized: "settings.hkdiag.never")
        }
        switch SyncTrigger(rawValue: raw) {
        case .foreground: return String(localized: "settings.hkdiag.trigger_foreground")
        case .background: return String(localized: "settings.hkdiag.trigger_background")
        case .push: return String(localized: "settings.hkdiag.trigger_push")
        case nil: return raw
        }
    }
}

// MARK: - Card

extension SettingsHKSyncDiagnosticsScreen {
    /// Server-Sicht: Urteil, Auslöser, Hintergrund-Beleg, Frische pro Typ.
    var serverHealthCard: some View {
        HLSettingsCard(
            icon: "antenna.radiowaves.left.and.right",
            title: "settings.hkdiag.server_title",
            // R5 — die Karte belegte beide Beitext-Slots. Der Untertitel („Was
            // der Server über diese Verbindung weiß.") formulierte nur den
            // Kartentitel um (Klasse A); der Footer trägt die Leseanleitung
            // („ein fehlender Typ hat noch nie geliefert, er steht nicht auf
            // null") und bleibt.
            footer: "settings.hkdiag.server_footer"
        ) {
            if let summary = serverSummary {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    if summary.hasServerData {
                        serverStatRow(
                            label: "settings.hkdiag.server_autonomy",
                            value: summary.autonomyLabel,
                            tint: summary.autonomyTint
                        )
                        serverStatRow(
                            label: "settings.hkdiag.server_verdict",
                            value: summary.verdictLabel,
                            tint: summary.verdictTint
                        )
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
                        serverStatRow(
                            label: "settings.hkdiag.server_last_background",
                            value: relativeOrNever(summary.lastBackgroundSyncAt),
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
                    HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                        Text(row.type)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.primary)
                        Spacer(minLength: HLSpace.sm)
                        Text(relativeOrNever(row.lastSeenAt))
                            .font(.hlCaption.monospacedDigit())
                            .foregroundStyle(row.stale ? HLColor.statusWarn : HLText.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func serverStatRow(label: LocalizedStringKey, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.md)
            Text(value)
                .font(.hlBody.monospacedDigit())
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
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
