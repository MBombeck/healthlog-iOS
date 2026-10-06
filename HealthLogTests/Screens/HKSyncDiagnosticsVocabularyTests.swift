// App-Target-Symbol (`HKSyncDiagnosticsVocabulary`) — nicht in der SPM-Library.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **K1 — die Sync-Diagnose zeigt Wörter, keine Bezeichner.**
    ///
    /// H2 fotografierte „foreground", „healthKitQuery", „failed" und
    /// „coldActivation" auf dem Bildschirm. Jede interne Aufzählung, die der
    /// Bildschirm zeigt, läuft durch ``HKSyncDiagnosticsVocabulary``; diese Suite
    /// füttert ihr jeden Fall und verlangt ein Wort, das nicht der Rohwert ist.
    @Suite("K1 — Sync-Diagnose: Vokabular statt Rohwerten")
    struct HKSyncDiagnosticsVocabularyTests {
        /// Jedes Wort, das `SpeziCollectionTrigger.run` je aufzeichnen kann: die
        /// Source-Wörter und die Trigger-Namen ohne Source-Entsprechung.
        static let triggerWords: [String] =
            ["background", "appRefresh", "foreground", "manual", "push"]
                + HealthSyncTrigger.allCases.map(\.rawValue)

        @Test("Jedes aufgezeichnete Auslöser-Wort hat eine Übersetzung", arguments: triggerWords)
        func everyTriggerWordIsNamed(_ raw: String) {
            let label = HKSyncDiagnosticsVocabulary.collectionTrigger(raw)
            #expect(!label.isEmpty)
            #expect(label != raw)
            #expect(label != HKSyncDiagnosticsVocabulary.unknown)
        }

        @Test("Ein unbekanntes Auslöser-Wort liest sich neutral, nicht roh")
        func unknownTriggerIsNeutral() {
            #expect(HKSyncDiagnosticsVocabulary.collectionTrigger("watchRelay") == HKSyncDiagnosticsVocabulary.unknown)
            #expect(HKSyncDiagnosticsVocabulary.collectionTrigger("") == HKSyncDiagnosticsVocabulary.unknown)
        }

        @Test("Jede Trainings-Quelle hat eine Übersetzung", arguments: WorkoutSyncSource.allCases)
        func everyWorkoutSourceIsNamed(_ source: WorkoutSyncSource) {
            let label = HKSyncDiagnosticsVocabulary.workoutSource(source)
            #expect(!label.isEmpty)
            #expect(label != source.rawValue)
            #expect(label != HKSyncDiagnosticsVocabulary.unknown)
        }

        @Test(
            "Jede Fehlerklasse hat eine Übersetzung",
            arguments: [
                HKSyncDiagnostics.WorkoutFailureClass.registration, .healthKitQuery, .transport,
                .serverRejected, .persistence, .cancelled, .unknown
            ]
        )
        func everyFailureIsNamed(_ failure: HKSyncDiagnostics.WorkoutFailureClass) {
            let label = HKSyncDiagnosticsVocabulary.workoutFailure(failure)
            #expect(!label.isEmpty)
            #expect(label != failure.rawValue)
        }

        @Test(
            "Jeder Import-Zustand hat eine Übersetzung",
            arguments: [
                HKSyncDiagnostics.WorkoutBackfillState.idle, .running, .progressed, .finished,
                .authorizationPending, .failed, .serverUnsupported
            ]
        )
        func everyBackfillStateIsNamed(_ state: HKSyncDiagnostics.WorkoutBackfillState) {
            let label = HKSyncDiagnosticsVocabulary.workoutBackfill(state)
            #expect(!label.isEmpty)
            #expect(label != state.rawValue)
        }

        @Test("Frische-Zeilen tragen den Namen der Messgröße, nicht den Server-Typ")
        func freshnessTypeIsTheMetricName() {
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("PULSE") == MetricKind.pulse.displayName)
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("RESPIRATORY_RATE") == MetricKind.respiratoryRate.displayName)
            #expect(HKSyncDiagnosticsVocabulary.freshnessType("BLOOD_PRESSURE_DIA") == MetricKind.bloodPressure.displayName)
        }

        // MARK: - Quellwächter

        private static func repoRoot(file: String = #filePath) -> URL {
            URL(fileURLWithPath: file)
                .deletingLastPathComponent() // Screens
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // <repo>
                .resolvingSymlinksInPath()
        }

        /// Der Fehler, den H2 fand, war ein `statRow(…, value: x.rawValue)`. Kein
        /// Wert einer Diagnose-Zeile darf wieder direkt aus einem Rohwert kommen.
        @Test("Kein Diagnose-Wert wird aus `.rawValue` gezeichnet")
        func noStatRowRendersARawValue() throws {
            let dir = Self.repoRoot().appendingPathComponent("HealthLog/Screens/Settings/Sub")
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix("SettingsHKSyncDiagnosticsScreen") && $0.hasSuffix(".swift") }
            #expect(files.count >= 4)
            let pattern = try Regex(#"value:[^\n]*\.rawValue"#)
            for file in files {
                let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                #expect(source.firstMatch(of: pattern) == nil, "\(file) zeichnet einen Rohwert")
                #expect(!source.contains("failure.rawValue"), "\(file) zeigt die Fehlerklasse roh")
            }
        }
    }
#endif
