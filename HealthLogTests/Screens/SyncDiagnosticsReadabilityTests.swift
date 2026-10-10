// App-Target-Symbole (`HKSyncDiagnosticsVocabulary`, `SyncActivityCopy`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **U1 (#18) — die Sync-Diagnose liest sich.**
    ///
    /// Gemeldet: `WORKOUTS` in Großbuchstaben neben `heart_rate`, und
    /// „F710 · M710 · S710 · A710 · X0" als Trainingszähler. Diese Suite pinnt
    /// die Namen der Frische-Liste und den Zählersatz.
    @Suite("U1 — Sync-Diagnose: Frische-Namen und Trainingssatz")
    struct HKSyncDiagnosticsReadabilityTests {
        @Test(
            "Kein Frische-Typ erscheint roh, egal in welcher Schreibweise",
            arguments: ["WORKOUTS", "workouts", "heart_rate", "HEART_RATE", "Resting-Heart-Rate", "pulse", "SOMETHING_NEW"]
        )
        func noRawFreshnessType(_ raw: String) {
            let name = HKSyncDiagnosticsVocabulary.freshnessType(raw)
            #expect(!name.isEmpty)
            #expect(name != raw)
            #expect(!name.contains("_"), "\(raw) → \(name)")
            #expect(name != name.uppercased() || name.count <= 4, "\(raw) → \(name) schreit")
        }

        @Test("Bekannte Typen tragen den Namen der Messgröße, unabhängig von der Schreibweise")
        func knownTypesAreMetricNames() {
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("pulse") == MetricKind.pulse.displayName)
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("resting-heart-rate") == MetricKind.restingHeartRate.displayName)
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("WORKOUTS") == String(localized: "settings.hkdiag.freshness.workouts"))
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("workouts") == String(localized: "settings.hkdiag.freshness.workouts"))
        }

        @Test("Unbekannte Typen werden zu einem Satzanfang, nicht zum Bezeichner")
        func unknownTypesArePrettified() {
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("HEART_RATE") == "Heart rate")
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("heart_rate") == "Heart rate")
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("___") == HKSyncDiagnosticsVocabulary.unknown)
        }

        @Test("Die Trainingszähler sind ein Satz, keine Buchstabenkette")
        func workoutCountsAreASentence() {
            var snapshot = HKSyncDiagnostics.WorkoutSnapshot()
            snapshot.fetchedTotal = 710
            snapshot.mappedTotal = 710
            snapshot.sentTotal = 710
            snapshot.acceptedTotal = 710
            snapshot.skippedTotal = 0
            let sentence = HKSyncDiagnosticsVocabulary.workoutCounts(snapshot)
            #expect(!sentence.contains("F 710") && !sentence.contains("·"))
            if Self.runsInGerman {
                #expect(sentence == "710 gelesen, 710 gesendet, 710 angenommen, 0 abgelehnt")
            }
            snapshot.mappedTotal = 707
            let withUnmapped = HKSyncDiagnosticsVocabulary.workoutCounts(snapshot)
            #expect(withUnmapped.hasPrefix(sentence))
            #expect(withUnmapped.contains("3"))
        }

        @Test("Neue Diagnose-Schlüssel haben de und en", arguments: Self.newKeys)
        func newKeysHaveParity(_ key: String) throws {
            let catalog = try ParityCatalog.load()
            let entry = try #require(catalog.strings[key], "\(key) fehlt im Katalog")
            for language in ["de", "en"] {
                // INT-L — the attention counts are plurals (`variations`).
                #expect(ParityCatalog.hasLocalization(entry, language: language), "\(key) ohne \(language)")
            }
        }

        static let newKeys = [
            "settings.hkdiag.freshness.workouts",
            "settings.hkdiag.workout_counts %lld %lld %lld %lld",
            "settings.hkdiag.workout_counts_unmapped %lld",
            "settings.hkdiag.workout_counts_label",
            "settings.hkdiag.workout_last_accepted",
            "settings.hkdiag.workout_history_import",
            "settings.hkdiag.workout_hr_backfill",
            "sync.activity.never",
            "sync.activity.lastSynced %@",
            "sync.activity.lastSyncedBackground %@",
            "sync.activity.a11y.synced %@",
            "sync.activity.a11y.syncedBackground %@",
            "sync.activity.a11y.done",
            "sync.activity.a11y.openHint",
            "sync.activity.attention.failed",
            "sync.activity.attention.queued %lld",
            "sync.activity.attention.stale",
            "sync.activity.attention.failedWrites %lld",
            "sync.activity.justNow",
            "sync.activity.showStatus",
            "sync.activity.healthHeld %lld"
        ]

        static var runsInGerman: Bool {
            Bundle.main.preferredLocalizations.first == "de"
        }
    }

    /// **U1 (#16) — was die Sync-Anzeige oben sagt.** Sichtbar kurz
    /// („vor 5 Min."), für VoiceOver ausgeschrieben („vor 5 Minuten").
    @Suite("U1 — SyncActivityCopy")
    struct SyncActivityCopyTests {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let german = Locale(identifier: "de_DE")

        @Test("Nie synchronisiert hat einen eigenen Satz")
        func neverSynced() {
            #expect(SyncActivityCopy.lastSyncLine(nil, now: now) == String(localized: "sync.activity.never"))
        }

        @Test("Vordergrund und Hintergrund unterscheiden sich, die Zeit ist relativ")
        func channelAndRelativeTime() {
            let fiveMinutesAgo = now.addingTimeInterval(-300)
            let foreground = SyncActivityCopy.lastSyncLine(SyncActivity(at: fiveMinutesAgo, channel: .foreground), now: now, locale: german)
            let background = SyncActivityCopy.lastSyncLine(SyncActivity(at: fiveMinutesAgo, channel: .background), now: now, locale: german)
            #expect(foreground != background)
            #expect(foreground.contains("vor 5 Min."), "\(foreground)")
            if HKSyncDiagnosticsReadabilityTests.runsInGerman {
                #expect(foreground == "Zuletzt synchronisiert vor 5 Min.")
                #expect(background == "Zuletzt synchronisiert vor 5 Min., im Hintergrund")
            }
        }

        @Test("VoiceOver hört die ausgeschriebene Zeit")
        func accessibilitySpellsOut() {
            let activity = SyncActivity(at: now.addingTimeInterval(-300), channel: .foreground)
            let spoken = SyncActivityCopy.lastSyncAccessibility(activity, now: now, locale: german)
            #expect(spoken.contains("vor 5 Minuten"), "\(spoken)")
            if HKSyncDiagnosticsReadabilityTests.runsInGerman {
                #expect(spoken == "Synchronisiert vor 5 Minuten")
            }
        }

        @Test("Unter einer Minute heißt es „gerade eben\"")
        func justNow() {
            let line = SyncActivityCopy.lastSyncLine(
                SyncActivity(at: now.addingTimeInterval(-12), channel: .foreground),
                now: now,
                locale: german
            )
            #expect(line.contains(String(localized: "sync.activity.justNow")))
            #expect(!line.contains("Sek."))
        }

        @Test("Jeder Aufmerksamkeitszustand hat einen Satz, der Zahl oder Zeit nennt")
        func attentionSentences() {
            #expect(SyncActivityCopy.attention(.failedWrites(3), now: now).contains("3"))
            #expect(SyncActivityCopy.attention(.queued(2), now: now).contains("2"))
            #expect(!SyncActivityCopy.attention(.failed, now: now).isEmpty)
            let stale = SyncActivityCopy.attention(.stale(since: now.addingTimeInterval(-2 * 86400)), now: now, locale: german)
            #expect(!stale.isEmpty)
        }

        /// INT-L (1.1.1) — the panel says the state as a plain sentence, not
        /// as an alert line; counts agree with their noun.
        @Test("Die Zustandssätze sind ganze, ruhige Sätze")
        func attentionSentencesArePlain() {
            guard HKSyncDiagnosticsReadabilityTests.runsInGerman else { return }
            #expect(SyncActivityCopy.attention(.failed, now: now) == "Die letzte Synchronisierung ist fehlgeschlagen.")
            #expect(SyncActivityCopy.attention(.queued(1), now: now) == "1 Eintrag wartet auf Verbindung.")
            #expect(SyncActivityCopy.attention(.queued(3), now: now) == "3 Einträge warten auf Verbindung.")
            #expect(SyncActivityCopy.attention(.failedWrites(1), now: now) == "1 Eintrag konnte nicht übertragen werden.")
            #expect(SyncActivityCopy.attention(.failedWrites(3), now: now) == "3 Einträge konnten nicht übertragen werden.")
            #expect(
                SyncActivityCopy.attention(.stale(since: now.addingTimeInterval(-2 * 86400)), now: now)
                    == "Seit mehr als einem Tag wurde nichts synchronisiert."
            )
        }

        /// INT-L (1.1.1) — rule for 1.1.1 copy: plain words, never
        /// joined with a middle dot, a dash or an arrow. Checked in the
        /// catalog so English is covered while the suite runs in German.
        @Test("Sync-Sätze oben kommen ohne Mittelpunkt, Gedankenstrich und Pfeil aus, de und en")
        func noDotOrDashJoins() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("HealthLog/Resources/Localizable.xcstrings"))
            let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(catalog["strings"] as? [String: Any])
            let keys = strings.keys.filter { $0.hasPrefix("sync.activity.") }
            #expect(keys.count >= 13)
            for key in keys {
                let entry = try #require(strings[key] as? [String: Any])
                let localizations = try #require(entry["localizations"] as? [String: Any])
                let encoded = try JSONSerialization.data(withJSONObject: localizations)
                let blob = String(bytes: encoded, encoding: .utf8) ?? ""
                for mark in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}"] {
                    #expect(!blob.contains(mark), "\(key) enthält \(mark)")
                }
            }
            let background = try #require(strings["sync.activity.lastSyncedBackground %@"] as? [String: Any])
            let encodedBackground = try JSONSerialization.data(withJSONObject: background)
            let blob = String(bytes: encodedBackground, encoding: .utf8) ?? ""
            #expect(blob.contains("Zuletzt synchronisiert %@, im Hintergrund"))
            #expect(blob.contains("Last synced %@, in the background"))
        }
    }
#endif
