// 15-04 (B5, decision E3) — a half tablet is unrecordable from the fast path.
//
// The deviating-dose UI exists in full and is finished: `MedicationFreeIntakeSheet`
// carries "Abweichende Dosis" with the placeholder "z. B. ½ Tablette", accepts a
// preselected medication, and posts `doseTaken` on the free-intake route. What
// is missing is the way in. The card's CTA fires `markIntakeQuick`, which has no
// dose parameter, and the card's context menu holds Bearbeiten and Archivieren.
// Reaching the dialog means remembering that "Manuell nachtragen" lives at the
// bottom of a sheet three taps away.
//
// The operator decided E3 on 2026-08-22: a LONG-PRESS on "Genommen" offers
// "Mit abweichender Dosis erfassen…" and leads into that same dialog. This suite
// measures the affordance and what it is seeded with, and pins that the plain
// tap keeps everything it has.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("The deviating dose reaches the fast path (15-04)")
    struct DeviatingDoseFastPathTests {
        private static let now = Date(timeIntervalSince1970: 1_700_000_000)

        private static func medication(
            id: String = "med_daily_0001",
            active: Bool = true,
            externalSource: String? = nil
        ) -> Medication {
            MedicationWireDTO(
                id: id,
                name: "Lisinopril",
                dose: "5 mg",
                active: active,
                schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00"])],
                asNeeded: false,
                externalSource: externalSource
            ).toDomain()
        }

        // MARK: - 1) the affordance exists

        /// E3: the entry point lives on the Genommen CTA. A card that can be
        /// marked at all can be marked with a different dose.
        @Test("Die Genommen-Taste bietet die abweichende Dosis an")
        func genommenLongPressOffersDeviatingDose() {
            let actions = MedicationCardActions.resolve(medication: Self.medication(), now: Self.now)

            #expect(
                actions.deviatingDose != nil,
                "EXPECTED_RED: the CTA has no long-press affordance"
            )
        }

        // MARK: - 2) it opens the dialog that already exists, prefilled

        /// Not a new dose editor: the existing "Manuell nachtragen" dialog,
        /// preselected on this medication, at the instant the gesture happened.
        @Test("Sie öffnet den vorhandenen Dialog, vorbelegt")
        func deviatingDoseOpensPrefilledDialog() {
            let medication = Self.medication()
            let actions = MedicationCardActions.resolve(medication: medication, now: Self.now)

            #expect(
                actions.deviatingDose == MedicationCardActions.DeviatingDose(
                    medicationID: medication.id,
                    takenAt: Self.now
                ),
                "EXPECTED_RED: the existing dialog is not reachable from the card"
            )
        }

        // MARK: - 3) only where a dose can be logged at all (control)

        /// A card with no manual dose logging — archived, or mirrored from
        /// Apple Health, which is source-exclusive (GH #47) — offers no CTA, so
        /// it offers no long-press either.
        @Test("Karten ohne manuelle Erfassung bieten sie nicht an")
        func cardsWithoutManualLoggingOfferNothing() {
            let archived = MedicationCardActions.resolve(
                medication: Self.medication(active: false),
                now: Self.now
            )
            let mirrored = MedicationCardActions.resolve(
                medication: Self.medication(externalSource: "APPLE_HEALTH"),
                now: Self.now
            )

            #expect(archived.deviatingDose == nil)
            #expect(mirrored.deviatingDose == nil)
        }

        // MARK: - 4) the context menu does not move (control)

        /// E3 is explicit: the deviating dose belongs on the CTA's long-press,
        /// not in the card's context menu. That menu keeps exactly the two
        /// items it has carried since T-3.
        @Test("Das Kontextmenü der Karte bleibt Bearbeiten und Archivieren")
        func cardContextMenuIsUnchanged() {
            let actions = MedicationCardActions.resolve(medication: Self.medication(), now: Self.now)
            #expect(actions.contextMenu == [.edit, .archive])
        }

        // MARK: - 5) the plain tap is untouched (control)

        /// The long-press is additive. Which dose a plain tap records
        /// (v0.14.1 ITEM-A: the most recent already-due slot, else the soonest
        /// upcoming one) is unchanged, and the double-fire guard still
        /// coalesces a second tap on the same intake.
        @Test("Der einfache Tipp verhält sich unverändert")
        @MainActor
        func plainTapIsUnchanged() throws {
            let medicationID = Self.medication().id
            let morning = MedicationIntake(
                id: "i-morning",
                medicationId: medicationID,
                scheduledAt: Self.now.addingTimeInterval(-8 * 3600),
                takenAt: nil,
                status: .pending
            )
            let evening = MedicationIntake(
                id: "i-evening",
                medicationId: medicationID,
                scheduledAt: Self.now.addingTimeInterval(-30 * 60),
                takenAt: nil,
                status: .pending
            )
            let upcoming = MedicationIntake(
                id: "i-upcoming",
                medicationId: medicationID,
                scheduledAt: Self.now.addingTimeInterval(3600),
                takenAt: nil,
                status: .pending
            )

            let dispatched = ActiveMedicationsSection.resolveDispatchDose(
                medicationId: medicationID,
                todayIntakes: [morning, evening, upcoming],
                now: Self.now
            )
            #expect(dispatched?.id == "i-evening", "ITEM-A: the most recent already-due slot")

            let nothingDueYet = ActiveMedicationsSection.resolveDispatchDose(
                medicationId: medicationID,
                todayIntakes: [upcoming],
                now: Self.now
            )
            #expect(nothingDueYet?.id == "i-upcoming", "else the soonest upcoming one")

            let repo = try MedicationsRepository(
                api: StubAPIClient(),
                outbox: OutboxQueue(inMemory: true)
            )
            let store = MedicationsStore(repo: repo)
            #expect(store.beginMark("i-evening"), "the first tap claims the in-flight slot")
            #expect(!store.beginMark("i-evening"), "the double-fire guard coalesces the second")
            store.endMark("i-evening")
            #expect(store.beginMark("i-evening"), "and releases it when the write settles")
        }
    }

#endif
