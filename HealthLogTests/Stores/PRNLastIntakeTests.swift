// 15-03 (B4) — a PRN card says nothing about its past and invents a future.
//
// The operator's B4 is "bei einem Bedarfsmedikament steht unter 'letzte
// Einnahme' nichts — und die nächste Einnahme ist für ein Bedarfsmedikament
// ohnehin sinnlos". Three things are wrong, and only the third is a server
// question:
//
//  1. The card renders `med.card.schedule.value.unset` — a bare em-dash — when
//     `lastTakenAt` is nil (`ActiveMedicationRow.swift`, `lastValue`). For a
//     medication that has a schedule that reads as "not yet"; for a PRN
//     medication, whose whole history IS its last intake, it reads as nothing.
//  2. The next-intake line renders unconditionally (v0.11 #24), so a PRN card
//     claims a next intake it cannot have — the engine projects nothing for
//     PRN, so the line falls back to `scheduleSummary`.
//  3. `lastTakenAt` rides the medication row, i.e. the `.medicationsList` cache
//     key — which no intake write invalidates (`intakeSiblingKeys` carries
//     compliance, dashboard and health-score only). A session that just
//     recorded an intake keeps reading its own stale list.
//
// Decoding is NOT among them: `MedicationWireDTO.lastTakenAt` decodes
// (`Medication.swift:460`) and maps verbatim into the domain (`:739`), and
// `ActiveMedicationsSection.swift:86` hands it to the card. Whether the SERVER
// fills it for an ad-hoc PRN intake is the open question that rides the B2
// issue; this suite pins the client half, which is complete either way.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("PRN cards state their last intake (15-03)", .serialized)
    struct PRNLastIntakeTests {
        private static let now = Date(timeIntervalSince1970: 1_700_000_000)

        /// The row the server answers the mark with — the same instant the
        /// fixture's `now` names, so nothing here depends on the wall clock.
        private static let intakeJSON = """
        {"data":{"id":"intake-1","medicationId":"med_prn_0001",        "scheduledFor":"2023-11-14T22:13:20Z","takenAt":"2023-11-14T22:13:20Z",        "skipped":false,"snoozedUntil":null}}
        """

        // MARK: - Fixtures

        /// The 09-14 spelling of PRN, from the pinned v1.37.24 contract
        /// fixture: the MEDICATION-level `asNeeded: true` with an empty
        /// `schedules` array. Never re-derived from schedule shapes.
        private static func prn(lastTakenAt: Date?) -> Medication {
            MedicationWireDTO(
                id: "med_prn_0001",
                name: "Naproxen",
                dose: "400 mg",
                active: true,
                notificationsEnabled: true,
                schedules: [],
                lastTakenAt: lastTakenAt,
                oneShot: false,
                asNeeded: true,
                createdAt: now.addingTimeInterval(-90 * 86400)
            ).toDomain()
        }

        /// A scheduled medication: one daily slot, not as-needed.
        private static func scheduled(lastTakenAt: Date?) -> Medication {
            MedicationWireDTO(
                id: "med_daily_0001",
                name: "Lisinopril",
                dose: "5 mg",
                active: true,
                notificationsEnabled: true,
                schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00"])],
                lastTakenAt: lastTakenAt,
                oneShot: false,
                asNeeded: false,
                createdAt: now.addingTimeInterval(-90 * 86400)
            ).toDomain()
        }

        private static func strip(
            for medication: Medication,
            lastTakenAt: Date?,
            nextDose: Date? = nil,
            windowStatus: MedicationWindowStatus? = nil,
            scheduleSummary: String = ""
        ) -> MedicationCardSchedule {
            MedicationCardSchedule.resolve(
                medication: medication,
                lastTakenAt: lastTakenAt,
                scheduleSummary: scheduleSummary,
                windowStatus: windowStatus,
                nextDose: nextDose,
                now: now
            )
        }

        // MARK: - 1) an honest empty, not a dash

        /// "Letzte Einnahme: —" is the answer a card gives when it has a
        /// schedule and simply has not been taken yet. On a PRN card the last
        /// intake is the entire record, so the empty case has to SAY that
        /// nothing is recorded — not leave a dash where the operator reads
        /// "nichts".
        @Test("Ohne erfasste Einnahme sagt die PRN-Karte das auch")
        func prnEmptyLastIntakeIsHonest() {
            let strip = Self.strip(for: Self.prn(lastTakenAt: nil), lastTakenAt: nil)

            #expect(strip.last.label == String(localized: "med.card.schedule.daily.last.label"))
            #expect(
                strip.last.value == String(localized: "med.card.schedule.last.none"),
                "EXPECTED_RED: the PRN card shows a bare dash where nothing was ever recorded"
            )
        }

        // MARK: - 2) no future a PRN medication does not have

        /// The operator's own rule: a next intake is meaningless for an
        /// as-needed medication. The card renders the line anyway, and for PRN
        /// the recurrence engine projects nothing — so the value falls back to
        /// the schedule summary, i.e. to whatever text happens to be lying
        /// around.
        @Test("Eine PRN-Karte behauptet keine nächste Einnahme")
        func prnCardHasNoNextIntakeLine() {
            let strip = Self.strip(
                for: Self.prn(lastTakenAt: nil),
                lastTakenAt: nil,
                scheduleSummary: "08:00 · 20:00"
            )

            #expect(
                strip.next == nil,
                "EXPECTED_RED: the card claims a next intake an as-needed medication cannot have"
            )
        }

        // MARK: - 3) the value the session just wrote

        /// `lastTakenAt` rides the medication row, so it is only as fresh as
        /// the `.medicationsList` cache. Recording an intake has to invalidate
        /// that key, or the card keeps showing the value it had before the
        /// write until the TTL happens to expire.
        @Test("Eine erfasste Einnahme entwertet die Medikamentenliste")
        @MainActor
        func intakeWriteInvalidatesListCache() async throws {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let coordinator = SWRCoordinator(cache: cache, reachability: AlwaysOnline())
            try await cache.write(
                .medicationsList,
                payload: JSONEncoder.hlDefault.encode([Self.prn(lastTakenAt: nil)])
            )

            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(Self.intakeJSON.utf8)
                )
            }
            let store = try Self.makeStore(session, swr: coordinator)
            store._testForceSet(todayIntakes: [
                MedicationIntake(
                    id: "intake-1",
                    medicationId: "med_prn_0001",
                    scheduledAt: Self.now,
                    takenAt: nil,
                    status: .pending
                )
            ])

            let outcome = await store.markIntakeQuick(intakeId: "intake-1", status: .taken, now: Self.now)

            #expect(outcome == .success)
            let after: Cached<[Medication]>? = await cache.read(.medicationsList, as: [Medication].self)
            #expect(
                after == nil,
                "EXPECTED_RED: the session that just wrote an intake keeps reading its stale list"
            )
        }

        // MARK: - 4) what a PRN card already got right (control)

        /// The server-published value renders — decoding was never the gap.
        @Test("Ein veröffentlichter Zeitpunkt wird angezeigt")
        func prnLastIntakeRendersTheServerValue() {
            let taken = Self.now.addingTimeInterval(-3 * 3600)
            let strip = Self.strip(for: Self.prn(lastTakenAt: taken), lastTakenAt: taken)

            #expect(strip.last.value == MedicationCard.relativeDateTime(taken, now: Self.now))
            #expect(strip.last.value != String(localized: "med.card.schedule.value.unset"))
        }

        // MARK: - 5) a scheduled card does not move (control)

        /// This plan differentiates PRN; it does not restyle anything. A
        /// scheduled medication keeps both lines, the same labels, the same
        /// relative value, the em-dash for an absent last intake, and
        /// "Jetzt fällig" while its window is open.
        @Test("Die Karte eines geplanten Medikaments ist unverändert")
        func scheduledCardIsUnchanged() {
            let medication = Self.scheduled(lastTakenAt: nil)
            let nextDose = Self.now.addingTimeInterval(6 * 3600)
            let strip = Self.strip(
                for: medication,
                lastTakenAt: nil,
                nextDose: nextDose,
                scheduleSummary: "08:00"
            )

            #expect(strip.last.label == String(localized: "med.card.schedule.daily.last.label"))
            #expect(strip.last.value == String(localized: "med.card.schedule.value.unset"))
            #expect(strip.next?.label == String(localized: "med.card.schedule.daily.next.label"))
            #expect(strip.next?.value == MedicationCard.relativeDateTime(nextDose, now: Self.now))

            let dueNow = Self.strip(
                for: medication,
                lastTakenAt: nil,
                nextDose: nextDose,
                windowStatus: .inWindow,
                scheduleSummary: "08:00"
            )
            #expect(dueNow.next?.value == String(localized: "med.card.status.take_now"))

            let noProjection = Self.strip(for: medication, lastTakenAt: nil, scheduleSummary: "08:00")
            #expect(noProjection.next?.value == "08:00", "the scheduleSummary fallback survives")
        }

        // MARK: - Harness

        private final class AlwaysOnline: ReachabilityProviding, @unchecked Sendable {
            var isOnlineStream: AsyncStream<Bool> {
                get async {
                    AsyncStream { continuation in
                        continuation.yield(true)
                        continuation.finish()
                    }
                }
            }

            func isCurrentlyOnline() async -> Bool {
                true
            }
        }

        @MainActor
        private static func makeStore(
            _ session: MockURLProtocolSession,
            swr: SWRCoordinator
        ) throws -> MedicationsStore {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(
                environment: AppEnvironment(
                    baseURL: session.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.19.0",
                    buildNumber: "1"
                ),
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
            let repo = try MedicationsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return MedicationsStore(repo: repo, swr: swr)
        }
    }

#endif

// swiftlint:enable force_unwrapping
