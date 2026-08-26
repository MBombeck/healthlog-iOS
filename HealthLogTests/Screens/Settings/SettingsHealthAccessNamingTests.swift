@testable import HealthLog
import Testing

#if canImport(HealthKit)
    import HealthKit
#endif

/// **v0.14.8 W2 follow-up #1 — Guideline 5.1.3(i) naming completeness.**
///
/// The transparency page (`SettingsHealthAccessScreen`) generates its read /
/// write lists from the authorization sets and resolves each identifier via
/// `HealthAccessTypeNaming`. Unmapped identifiers fail soft (raw-identifier
/// fallback), which keeps the type *visible* but reads like debug output —
/// the W2 walkthrough caught "AppleWalkingSteadiness", "RespiratoryRate" and
/// "HKWorkoutTypeIdentifier" leaking raw. These tests pin the contract that
/// every identifier the app can ever put on the transparency lists has a
/// localized display name, so a future type addition without a name entry
/// fails CI instead of shipping a raw symbol to the user.
@Suite("HealthAccess transparency naming")
struct SettingsHealthAccessNamingTests {
    #if canImport(HealthKit)
        @Test("every default read type has a localized display name — no raw-identifier fallback")
        func defaultReadTypesAllMapped() {
            for identifier in HealthKitService.defaultReadTypes.map(\.identifier) {
                #expect(
                    HealthAccessTypeNaming.localizationKey(for: identifier) != nil,
                    "unmapped HealthKit read type leaks a raw identifier onto the transparency list: \(identifier)"
                )
            }
        }

        @Test("every default write type has a localized display name — no raw-identifier fallback")
        func defaultWriteTypesAllMapped() {
            for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                #expect(
                    HealthAccessTypeNaming.localizationKey(for: identifier) != nil,
                    "unmapped HealthKit write type leaks a raw identifier onto the transparency list: \(identifier)"
                )
            }
        }

        @Test("every gated cycle type has a localized display name — no raw-identifier fallback")
        func cycleTypesAllMapped() {
            for identifier in CycleHealthKitImporter.readCategoryTypes().map(\.identifier) {
                #expect(
                    HealthAccessTypeNaming.localizationKey(for: identifier) != nil,
                    "unmapped cycle type leaks a raw identifier onto the transparency list: \(identifier)"
                )
            }
        }

        /// **Von 16-03 bewusst geändert (Entscheidung E2, Betreiber
        /// 2026-08-22): „EKG und Stimmung wandern in das erste
        /// HealthKit-Sheet."**
        ///
        /// Der alte Vertrag war ein Tor: der State-of-Mind-Typ erschien auf der
        /// 5.1.3(i)-Fläche nur, solange der Einstellungs-Schalter an war, weil
        /// er sonst gar nicht angefragt wurde. Seit E2 ist er Mitglied beider
        /// Standardmengen, also steht er dort **bedingungslos** — und das Tor
        /// selbst ist entfernt, nicht auf `false` gestellt: ein totes Tor liest
        /// sich wie eine lebende Regel.
        ///
        /// Der Test wurde nicht gelöscht und nicht abgeschwächt. Er hält
        /// weiterhin genau eine Sache fest — dass der Typ auf der Fläche steht
        /// und dort einen übersetzten Namen hat — nur nicht mehr abhängig von
        /// einem Schalter, den es für diesen Zweck nicht mehr gibt.
        @Test("Stimmung steht seit E2 bedingungslos auf der Transparenzfläche, mit Namen")
        func moodTypeIsUnconditionalOnTheTransparencyPage() {
            let mood = HKObjectType.stateOfMindType().identifier
            #expect(mood == "HKDataTypeStateOfMind", "der Bezeichner, an dem die Namenstabelle hängt")

            // Lesen UND Schreiben: die App spiegelt erfasste Stimmungen zurück.
            #expect(HealthKitService.defaultReadTypes.map(\.identifier).contains(mood))
            #expect(HealthKitService.defaultWriteTypes.map(\.identifier).contains(mood))

            // Genau einmal, nicht zweimal: die beiden bedingten Joins, die ihn
            // früher hierher brachten, sind weg — sonst trüge die Liste zwei
            // Zeilen mit derselben `id`.
            let listed = SettingsHealthAccessScreen.readTypeIdentifiers(cycleIdentifiers: [])
            #expect(listed.filter { $0 == mood }.count == 1)

            #expect(HealthAccessTypeNaming.localizationKey(for: mood) != nil)
            #expect(HealthAccessTypeNaming.displayName(for: mood) != mood)
        }

        /// **Von 16-03 bewusst geändert — dieselbe Begründung wie oben, GH #74.**
        ///
        /// „Im Onboarding fragt niemand nach einer Herzkurve" war richtig,
        /// solange es keinen Ort gab, an den sie gehen konnte. Server v1.35.3
        /// hat den geschaffen, und E2 hat entschieden, dass sie deshalb in den
        /// ersten Dialog gehört. Der Vertrag wandert mit.
        @Test("GH #74 / E2 — der EKG-Typ steht bedingungslos auf der Fläche, und mit Namen")
        func ecgTypeIsUnconditionalOnTheTransparencyPage() {
            let ecg = HKObjectType.electrocardiogramType().identifier
            #expect(HealthKitService.defaultReadTypes.map(\.identifier).contains(ecg))

            let listed = SettingsHealthAccessScreen.readTypeIdentifiers(cycleIdentifiers: [])
            #expect(listed.filter { $0 == ecg }.count == 1)

            #expect(
                HealthAccessTypeNaming.localizationKey(for: ecg) != nil,
                "der EKG-Typ zeigt sonst seinen rohen Bezeichner: \(ecg)"
            )
            #expect(HealthAccessTypeNaming.displayName(for: ecg) != ecg)
        }

        /// **Von 16-03 geändert, aber nur zur Hälfte — und die stehengebliebene
        /// Hälfte ist die wichtigere.**
        ///
        /// Der Lesetyp ist jetzt im Standardpaket (E2). Was unverändert gilt und
        /// hier weiter festgenagelt wird: er ist NIRGENDS im Schreibpaket.
        /// `HKReadinessStore` leitet seinen Verbindungszustand ausschliesslich
        /// aus SCHREIB-Typen ab, ein Lesetyp ist also strukturell ausserstande,
        /// ihn zu bewegen — kein neues „teilweise erteilt" wegen des EKGs, kein
        /// neues Rot auf dem Dashboard. (Der State-of-Mind-Typ ist der einzige,
        /// der das Schreibpaket in diesem Plan vergrössert; seine Folgen sind in
        /// `FirstSheetTypeSetTests` beidseitig festgenagelt.)
        @Test("GH #74 — EKG bleibt ein reiner Lesetyp und kann den Verbindungszustand nicht verfälschen")
        func ecgIsReadOnlyAndCannotDistortReadiness() {
            let ecg = HKObjectType.electrocardiogramType().identifier
            #expect(!HealthKitService.defaultWriteTypes.map(\.identifier).contains(ecg))

            // Und der Beweis, dass das genügt: mit allen Schreibtypen erteilt
            // ist der Zustand vollständig erteilt — der EKG-Lesetyp kommt in
            // dieser Rechnung gar nicht vor.
            var statuses: [String: HKReadinessStore.AuthStatus] = [:]
            for identifier in HealthKitService.defaultWriteTypes.map(\.identifier) {
                statuses[identifier] = .sharingAuthorized
            }
            #expect(HKReadinessStore.computeState(statuses: statuses, hasRequestedAuthorization: true) == .fullyGranted)
        }

        @Test("the W2-flagged stragglers resolve to their localized names, not raw identifiers")
        func w2StragglersResolve() {
            // The four identifiers that fell back to raw names before the W2
            // follow-up fix. `displayName(for:)` must not return the raw
            // (prefix-stripped) identifier for any of them anymore.
            let stragglers = [
                "HKQuantityTypeIdentifierRespiratoryRate",
                "HKQuantityTypeIdentifierAppleWalkingSteadiness",
                "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
                "HKWorkoutTypeIdentifier"
            ]
            for identifier in stragglers {
                #expect(HealthAccessTypeNaming.localizationKey(for: identifier) != nil)
                let name = HealthAccessTypeNaming.displayName(for: identifier)
                #expect(name != identifier)
                #expect(name != identifier
                    .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                    .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""))
            }
        }
    #endif
}
