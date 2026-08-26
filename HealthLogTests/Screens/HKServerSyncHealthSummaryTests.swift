// App-Target-Symbol (`HKServerSyncHealthSummary`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **CU-21 (2) — Akzeptanz: die Diagnostikfläche rendert Verdict + Frische,
    /// und ein unbekanntes Verdict crasht nicht.**
    ///
    /// Assertiert gegen die Ableitung, nicht gegen lokalisierten Text — gleiches
    /// Muster wie `SettingsHKSyncDiagnosticsStatusTests` für ``KindRow``.
    ///
    /// Der Kern ist ``HKServerSyncHealthSummary/autonomy``: das ist die eine
    /// Zeile, an der der Operator nach zwei bis drei Tagen Gerätegebrauch
    /// ablesen soll, ob dieses iPhone auch ohne geöffnete App liefert — ohne die
    /// Web-Oberfläche danebenzulegen.
    @Suite("CU-21 — HKServerSyncHealthSummary")
    struct HKServerSyncHealthSummaryTests {
        private static let anchor = Date(timeIntervalSince1970: 1_753_862_400)

        // MARK: - Die Frage, für die die Einheit existiert

        @Test("`lastSyncTrigger == background` ⇒ liefert selbstständig (belegt)")
        func backgroundTriggerConfirmsAutonomy() {
            let summary = HKServerSyncHealthSummary(verdict: .fresh, lastSyncTrigger: "background")
            #expect(summary.autonomy == .confirmed)
        }

        @Test("`lastSyncTrigger == push` ⇒ liefert selbstständig (belegt)")
        func pushTriggerConfirmsAutonomy() {
            let summary = HKServerSyncHealthSummary(verdict: .fresh, lastSyncTrigger: "push")
            #expect(summary.autonomy == .confirmed)
        }

        @Test("Ein Hintergrund-Zeitstempel belegt Autonomie auch bei zuletzt gesehenem Vordergrund-Sweep")
        func backgroundTimestampOutweighsLastTrigger() {
            // Realistischer Alltag: nachts kam ein BGTask durch, morgens öffnet
            // der Operator die App. Der letzte Auslöser ist dann `foreground` —
            // die Autonomie ist trotzdem bewiesen.
            let summary = HKServerSyncHealthSummary(
                verdict: .fresh,
                lastSyncTrigger: "foreground",
                lastBackgroundSyncAt: Self.anchor
            )
            #expect(summary.autonomy == .confirmed)
        }

        @Test("Nur Vordergrund-Sweeps gesehen ⇒ ehrliche Negativ-Antwort, kein Fehlerzustand")
        func foregroundOnlyIsHonest() {
            let summary = HKServerSyncHealthSummary(verdict: .fresh, lastSyncTrigger: "foreground")
            #expect(summary.autonomy == .foregroundOnly)
        }

        @Test("Kein Auslöser bekannt ⇒ `unknown`, nicht `nein`")
        func noTriggerIsUnknownNotNo() {
            let summary = HKServerSyncHealthSummary(verdict: nil)
            #expect(summary.autonomy == .unknown)
            #expect(summary.hasServerData == false)
        }

        @Test("Ein unbekanntes Auslöser-Wort ist `unknown`, nicht stillschweigend `nein`")
        func unknownTriggerWordIsUnknown() {
            let summary = HKServerSyncHealthSummary(verdict: .fresh, lastSyncTrigger: "watch_relay")
            #expect(summary.autonomy == .unknown)
            // Wörtlich angezeigt statt verschwiegen.
            #expect(summary.triggerLabel == "watch_relay")
        }

        // MARK: - Verdict

        @Test("Ein unbekanntes Verdict crasht nicht und wird wörtlich gezeigt")
        func unknownVerdictRendersVerbatim() {
            let summary = HKServerSyncHealthSummary(verdict: .unknown("quarantined_by_ops"))
            #expect(summary.verdictLabel == "quarantined_by_ops")
            // Und es färbt die Fläche NICHT rot — niemand weiß, was es bedeutet.
            #expect(summary.verdictTint == HLText.secondary)
        }

        @Test(
            "Nur die handlungsrelevanten Verdicts verlangen Aufmerksamkeit",
            arguments: [
                (SyncHealthVerdict.fresh, false),
                (.stale, false),
                (.pendingFirstSync, false),
                (.stalled, true),
                (.failing, true),
                (.reauthRequired, true),
                (.parked, true),
                (.disconnected, true)
            ]
        )
        func attentionClassification(verdict: SyncHealthVerdict, expected: Bool) {
            #expect(verdict.needsAttention == expected)
            let summary = HKServerSyncHealthSummary(verdict: verdict)
            #expect((summary.verdictTint == HLColor.statusWarn) == expected)
        }

        @Test("Ohne Verdict bleibt die Zeile neutral statt zu behaupten, alles sei in Ordnung")
        func missingVerdictIsNeutral() {
            let summary = HKServerSyncHealthSummary(verdict: nil, lastSyncTrigger: "foreground")
            #expect(summary.verdictTint == HLText.tertiary)
            #expect(summary.hasServerData == true)
        }

        // MARK: - Frische

        @Test("Frische wird durchgereicht; ein fehlender Typ bleibt abwesend")
        func freshnessPassthrough() {
            let config = HealthKitSyncConfig(
                entries: [],
                lastSyncedAt: nil,
                metricFreshness: [
                    MetricFreshness(type: "weight", lastSeenAt: Self.anchor, stale: false)
                ]
            )
            let summary = HKServerSyncHealthSummary(config: config)
            #expect(summary.freshness?.map(\.type) == ["weight"])
            #expect(summary.freshness?.contains { $0.type == "heart_rate" } == false)
        }

        @Test("`nil` (Feld unbekannt) und `[]` (nichts geliefert) bleiben unterscheidbar")
        func freshnessNilVsEmpty() {
            let missing = HKServerSyncHealthSummary(
                config: HealthKitSyncConfig(entries: [], lastSyncedAt: nil)
            )
            let empty = HKServerSyncHealthSummary(
                config: HealthKitSyncConfig(entries: [], lastSyncedAt: nil, metricFreshness: [])
            )
            #expect(missing.freshness == nil)
            #expect(empty.freshness?.isEmpty == true)
            #expect(missing.hasServerData == false)
            #expect(empty.hasServerData == true)
        }

        // MARK: - Übernahme aus der Wire-Form

        @Test("Die Zusammenfassung liest exakt die vier GET-Felder aus der Config")
        func initFromConfig() {
            let config = HealthKitSyncConfig(
                entries: [],
                lastSyncedAt: nil,
                lastSyncTrigger: "push",
                lastBackgroundSyncAt: Self.anchor,
                syncHealth: HealthKitSyncHealth(verdict: .stalled, since: Self.anchor),
                metricFreshness: []
            )
            let summary = HKServerSyncHealthSummary(config: config)
            #expect(summary.verdict == .stalled)
            #expect(summary.since == Self.anchor)
            #expect(summary.lastSyncTrigger == "push")
            #expect(summary.lastBackgroundSyncAt == Self.anchor)
            #expect(summary.autonomy == .confirmed)
        }
    }

#endif
