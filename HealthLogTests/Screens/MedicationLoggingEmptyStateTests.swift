import Foundation
@testable import HealthLog
import SnapshotTesting
import Testing

// swiftlint:disable force_unwrapping

/// **CU-24 (GH iOS #73)** — the two medication-logging dead ends.
///
/// Reported against `0.17.0` on TestFlight: on an account with **no active
/// medications**, both entry points ended nowhere. The free-log sheet showed
/// "Keine aktiven Medikamente zum Nachtragen." with a disabled save button, and
/// the quick-intake sheet claimed "Gerade ist nichts fällig. Schau später wieder
/// rein." — an instruction that can never come true, because nothing becomes due
/// until a medication exists.
///
/// The distinction is already answerable from the client with the two reads that
/// exist today, and this suite drives them through the **real** `APIClient` over
/// `MockURLProtocol` (per PROJECT_GUIDE.md — never a mock server) so a schema change on
/// either route surfaces here:
///
/// - `GET /api/medications` empty → ``MedicationLoggingEmptyState/noMedications``:
///   nothing to log against until one is created, so the create flow is the
///   primary action and manual logging is not offered (it would be a second
///   dead end).
/// - non-empty list + `GET /api/medications/intake?scope=today` empty →
///   ``MedicationLoggingEmptyState/nothingDue``: a real, temporary state whose
///   existing copy is correct and stays, with manual logging as the useful
///   secondary action.
///
/// `.serialized` because `MockURLProtocol.handler` is a process-global.
///
/// **This suite does not close the ticket.** The reporter confirms on TestFlight;
/// see the walkthrough checklist in the CU-24 report.
@Suite("CU-24 — Medikamenten-Logging: leere Liste vs. nichts fällig", .serialized)
@MainActor
struct MedicationLoggingEmptyStateTests {
    // MARK: - Fixtures

    private nonisolated static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func makeAPIClient() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.17.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    /// Serves the three reads `MedicationsStore.load()` makes on its direct
    /// (no-SWR) path. `medicationsJSON` is the raw `GET /api/medications` array
    /// body — the single knob that separates the two states under test; today's
    /// intake set is empty in every case here, because that is precisely the
    /// situation in which the two empty states used to be indistinguishable.
    private func installHandler(medicationsJSON: String) {
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let query = req.url?.query ?? ""
            if path == "/api/medications", req.httpMethod == "GET" {
                return (Self.ok(req), Data(#"{"data":\#(medicationsJSON)}"#.utf8))
            }
            if path == "/api/medications/intake", query.contains("scope=today") {
                return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
            }
            // Compliance sweep + list layout — not under test, answered so the
            // load settles instead of parking an error on the store.
            return (Self.ok(req), Data(#"{"data":[]}"#.utf8))
        }
    }

    private func makeStore(medicationsJSON: String) async throws -> MedicationsStore {
        installHandler(medicationsJSON: medicationsJSON)
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: makeAPIClient(), outbox: outbox)
        let store = MedicationsStore(repo: repo)
        await store.load()
        return store
    }

    private func dump(of value: some Any) -> String {
        var output = ""
        Swift.dump(value, to: &output)
        return output
    }

    /// The empty state the sheets resolve from the live store — the exact
    /// expression both `MedicationQuickIntakeSheet` and
    /// `MedicationFreeIntakeSheet` evaluate.
    private func resolved(from store: MedicationsStore) -> MedicationLoggingEmptyState {
        .resolve(
            hasLoadedMedications: store.hasLoadedMedications,
            hasActiveMedications: store.medications.contains(where: \.active)
        )
    }

    // MARK: - The two states, from fixtures

    @Test("Leere GET /api/medications → noMedications (kein 'schau später wieder rein')")
    func emptyMedicationListResolvesToNoMedications() async throws {
        let store = try await makeStore(medicationsJSON: "[]")

        #expect(store.hasLoadedMedications, "the list must be hydrated before either claim is made")
        #expect(store.medications.isEmpty)
        #expect(store.todayIntakes.isEmpty)

        let state = resolved(from: store)
        #expect(state == .noMedications)

        let descriptor = try #require(state.presentationDescriptor())
        // The create flow is the way out — this is the whole point of the ticket.
        #expect(descriptor.primaryAction == .addMedication)
        // Manual logging here would be the second dead end the reporter hit.
        #expect(!descriptor.offersManualLog)
        // And the "nothing due right now" copy must not be reachable from here.
        #expect(descriptor.messageKey == "meds.empty.noMeds.logging.message")
        #expect(descriptor.messageKey != "meds.quick.empty.subtitle")
    }

    @Test("Nicht-leere Liste + leere heutige Einnahmen → nothingDue (Copy bleibt)")
    func populatedListWithNoDueIntakesResolvesToNothingDue() async throws {
        let store = try await makeStore(
            medicationsJSON: #"[{"id":"med-1","name":"Vitamin D","dose":"1000 IE","active":true}]"#
        )

        #expect(store.medications.count == 1)
        #expect(store.todayIntakes.isEmpty, "nothing is due — the state that is legitimately temporary")

        let state = resolved(from: store)
        #expect(state == .nothingDue)

        let descriptor = try #require(state.presentationDescriptor())
        // The pre-existing copy is correct in this branch and is kept verbatim.
        #expect(descriptor.titleKey == "meds.quick.empty.title")
        #expect(descriptor.messageKey == "meds.quick.empty.subtitle")
        // Logging manually against an active medication is the useful secondary.
        #expect(descriptor.offersManualLog)
        #expect(descriptor.primaryAction == nil, "an account that already has medications must not be nagged to create one")
    }

    @Test("Nur archivierte Medikamente zählen nicht als loggbar → noMedications")
    func archivedOnlyListResolvesToNoMedications() async throws {
        let store = try await makeStore(
            medicationsJSON: #"[{"id":"med-old","name":"Naproxen","dose":"400 mg","active":false}]"#
        )

        #expect(store.medications.count == 1)
        // An archived / paused medication cannot receive an intake, so the
        // account is not loggable and "check back later" would be just as wrong.
        #expect(resolved(from: store) == .noMedications)
    }

    @Test("Vor der Hydration wird nichts behauptet → loading")
    func unhydratedStoreClaimsNothing() {
        let state = MedicationLoggingEmptyState.resolve(
            hasLoadedMedications: false,
            hasActiveMedications: false
        )
        #expect(state == .loading)
        #expect(state.presentationDescriptor() == nil, "a spinner, not a copy block — `medications == []` is ambiguous until loaded")
    }

    // MARK: - Dose path cannot show an empty state while medications exist

    /// Issue #73 point 3: with active medications the free-log ("Dosis"-)path
    /// must not be able to render an empty state at all. It is empty-by-
    /// construction only when its candidate list — the active medications — is
    /// empty, so the two conditions coincide and there is no separate defect.
    @Test("Freilog-Pfad kann bei aktiven Medikamenten keinen Leerzustand zeigen")
    func freeLogPathHasNoEmptyStateWhileActiveMedicationsExist() async throws {
        let store = try await makeStore(
            medicationsJSON: #"[{"id":"med-1","name":"Vitamin D","dose":"1000 IE","active":true}]"#
        )
        // Same predicate the sheet's `emptyState` guard uses: `candidates` is
        // `medications.filter(\.active)`, and the guard is `candidates.isEmpty`.
        let candidates = store.medications.filter(\.active)
        #expect(!candidates.isEmpty)
    }

    // MARK: - The create CTA really is the create flow

    /// The primary action is modelled as a value with exactly one case, and the
    /// shared empty-state view is the single place that maps it — onto the same
    /// `AddMedicationSheet` the Medikamente tab presents. Pinned by reading the
    /// source (the mapping is a SwiftUI `.sheet` body, which headless tests
    /// cannot enter), in the same spirit as `PercentFormatLintTests`.
    @Test("'Medikament anlegen' ist auf AddMedicationSheet verdrahtet")
    func createCTALeadsIntoTheCreateFlow() throws {
        #expect(MedicationLoggingEmptyState.PrimaryAction.addMedication.rawValue == "addMedication")

        let source = try String(contentsOf: Self.emptyStateSourceURL, encoding: .utf8)
        #expect(
            source.contains("AddMedicationSheet("),
            "the .addMedication CTA must present the same create flow the Medikamente tab uses"
        )
        #expect(
            source.contains("descriptor.primaryAction == .addMedication"),
            "the CTA must be gated on the enum, not on an ad-hoc flag"
        )
    }

    private static var emptyStateSourceURL: URL {
        // <repo>/HealthLogTests/Screens/<this file>
        //   → <repo>/HealthLog/Screens/Medications/MedicationLoggingEmptyState.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HealthLog/Screens/Medications/MedicationLoggingEmptyState.swift")
    }

    // MARK: - Snapshots of both empty states

    @Test("Snapshot — Leerzustand ohne aktive Medikamente")
    func noMedicationsEmptyStateSnapshot() throws {
        let descriptor = try #require(MedicationLoggingEmptyState.noMedications.presentationDescriptor())
        assertSnapshot(of: dump(of: descriptor), as: .lines, named: "empty-no-medications")
    }

    @Test("Snapshot — Leerzustand 'gerade nichts fällig'")
    func nothingDueEmptyStateSnapshot() throws {
        let descriptor = try #require(MedicationLoggingEmptyState.nothingDue.presentationDescriptor())
        assertSnapshot(of: dump(of: descriptor), as: .lines, named: "empty-nothing-due")
    }

    // MARK: - One intent, one term

    /// Vocabulary guard for the logging surfaces. "Dosis" / "dose" stays correct
    /// for the **amount** (`med.freelog.dose.*` is the deviating-amount field),
    /// but the **act** of logging or marking is "Einnahme" / "intake" on every
    /// surface — the reporter met two vocabularies for one goal.
    ///
    /// Scoped to the namespaces this ticket owns rather than the whole catalog,
    /// because a catalog-wide ban would fire on legitimate amount wording
    /// (Dosisstärke, Dosen pro Einheit). Recorded in `ParityGlossary.json`.
    @Test("Kein 'Dosis'/'dose' für den Vorgang in den Logging-Namespaces")
    func loggingSurfacesUseOneTerm() throws {
        let catalog = try ParityCatalog.load()
        let guardedPrefixes = ["meds.quick.", "med.freelog.", "meds.empty."]
        // The deviating-AMOUNT field: "Abweichende Dosis" is the right word there.
        let amountPrefixes = ["med.freelog.dose."]
        let german = try Regex(#"(?i)\b(dosis|dosen)\b"#)
        let english = try Regex(#"(?i)\b(dose|doses)\b"#)

        var offenders: [String] = []
        var scanned = 0
        for (key, entry) in catalog.strings
            where guardedPrefixes.contains(where: key.hasPrefix)
            && !amountPrefixes.contains(where: key.hasPrefix)
        {
            scanned += 1
            if let de = ParityCatalog.value(entry, language: "de"), de.contains(german) {
                offenders.append("\(key) [de]: \(de)")
            }
            if let en = ParityCatalog.value(entry, language: "en"), en.contains(english) {
                offenders.append("\(key) [en]: \(en)")
            }
        }

        // Sanity: a namespace rename must not let this pass vacuously.
        #expect(scanned >= 20, "expected the logging namespaces, scanned \(scanned) keys")
        #expect(
            offenders.isEmpty,
            "One intent, one term — use Einnahme / intake for the act of logging:\n\(offenders.sorted().joined(separator: "\n"))"
        )
    }

    /// The two entry points into that one intent must not disagree with each
    /// other either — the picker row said "Einnahme erfassen" over "Heutige
    /// Dosis abhaken", and the Today rail said "Dosis erfassen".
    @Test("Einstiegspunkte sprechen dieselbe Sprache")
    func entryPointsShareTheVocabulary() throws {
        let catalog = try ParityCatalog.load()
        for key in ["capture.picker.medication.title", "capture.picker.medication.subtitle", "daily.action.logDose"] {
            let entry = try #require(catalog.strings[key], "missing \(key)")
            let de = try #require(ParityCatalog.value(entry, language: "de"))
            let en = try #require(ParityCatalog.value(entry, language: "en"))
            #expect(de.localizedCaseInsensitiveContains("Einnahme"), "\(key) [de] should name the intent: \(de)")
            #expect(en.localizedCaseInsensitiveContains("intake"), "\(key) [en] should name the intent: \(en)")
        }
    }
}

// swiftlint:enable force_unwrapping
