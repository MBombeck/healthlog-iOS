// 15-04 (B6) — "über Erfassen lässt sich nichts erfassen".
//
// The Erfassen → Einnahme-erfassen sheet asks exactly one question: which of
// today's slots is due? (`MedicationQuickIntakeOptions.resolve` — pending
// intakes with `scheduledAt <= now`, joined to their active medication.) A PRN
// medication has no slot, so it can never be due, so the sheet cannot offer it
// — not because a filter excludes it, but because the sheet has no second
// question to ask. The operator's Naproxen is therefore unreachable from the
// central recording CTA.
//
// The recording machinery it needs already exists and is correct: the
// free-intake path (`MedicationsStore.logIntakeFree`, `POST
// /api/medications/{id}/intake`) records an ad-hoc dose at an arbitrary instant
// and invalidates the same keys every other intake write does. This suite pins
// that machinery as a control and measures the missing reach as the RED.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("Erfassen offers PRN (15-04)", .serialized)
    struct QuickIntakePRNTests {
        private static let now = Date(timeIntervalSince1970: 1_700_000_000)

        // MARK: - Fixtures

        /// The 09-14 spelling: medication-level `asNeeded: true`, `schedules: []`.
        private static let prn = MedicationWireDTO(
            id: "med_prn_0001",
            name: "Naproxen",
            dose: "400 mg",
            active: true,
            schedules: [],
            asNeeded: true
        ).toDomain()

        private static let scheduledMed = MedicationWireDTO(
            id: "med_daily_0001",
            name: "Lisinopril",
            dose: "5 mg",
            active: true,
            schedules: [MedicationScheduleDTO(windowStart: "08:00", timesOfDay: ["08:00"])],
            asNeeded: false
        ).toDomain()

        private static func dueIntake(id: String, minutesAgo: Int) -> MedicationIntake {
            MedicationIntake(
                id: id,
                medicationId: scheduledMed.id,
                scheduledAt: now.addingTimeInterval(-Double(minutesAgo) * 60),
                takenAt: nil,
                status: .pending
            )
        }

        // MARK: - 1) the PRN medication is on the list

        /// One PRN medication, nothing due: the sheet has to offer it. Today it
        /// offers nothing at all and paints "gerade nichts fällig" — over a
        /// medication whose whole point is that it is never scheduled.
        @Test("Ein Bedarfsmedikament ist im Erfassen-Blatt wählbar")
        func prnMedicationIsSelectable() {
            let options = MedicationQuickIntakeOptions.resolve(
                medications: [Self.prn],
                intakes: [],
                now: Self.now
            )

            #expect(
                options.asNeeded.map(\.id) == [Self.prn.id],
                "EXPECTED_RED: the quick sheet structurally excludes PRN"
            )
            #expect(!options.isEmpty, "a PRN-only account must not read as 'nothing to record'")
        }

        /// An archived PRN medication is not an option — the same rule the due
        /// list applies to its own rows.
        @Test("Ein archiviertes Bedarfsmedikament wird nicht angeboten")
        func archivedPrnIsNotOffered() {
            let archived = MedicationWireDTO(
                id: "med_prn_archived",
                name: "Altes Mittel",
                dose: "1 Tablette",
                active: false,
                schedules: [],
                asNeeded: true
            ).toDomain()

            let options = MedicationQuickIntakeOptions.resolve(
                medications: [archived],
                intakes: [],
                now: Self.now
            )

            #expect(options.asNeeded.isEmpty)
            #expect(options.isEmpty, "an archived-only account still has nothing to record")
        }

        // MARK: - 2) the due list does not move (control)

        /// The sheet's due-slot semantics are documented in its own header and
        /// are not this plan's to touch: pending, past-due, earliest first,
        /// active medication only — and an as-needed medication never appears
        /// among them, even when it is offered beside them.
        @Test("Die Auflösung fälliger Dosen ist unverändert")
        func dueResolutionIsUnchanged() {
            let taken = MedicationIntake(
                id: "i-taken",
                medicationId: Self.scheduledMed.id,
                scheduledAt: Self.now.addingTimeInterval(-7200),
                takenAt: Self.now,
                status: .taken
            )
            let future = MedicationIntake(
                id: "i-future",
                medicationId: Self.scheduledMed.id,
                scheduledAt: Self.now.addingTimeInterval(3600),
                takenAt: nil,
                status: .pending
            )
            let archivedMedIntake = MedicationIntake(
                id: "i-archived",
                medicationId: "med_archived",
                scheduledAt: Self.now.addingTimeInterval(-1800),
                takenAt: nil,
                status: .pending
            )

            let options = MedicationQuickIntakeOptions.resolve(
                medications: [Self.scheduledMed, Self.prn],
                intakes: [
                    Self.dueIntake(id: "i-late", minutesAgo: 30),
                    Self.dueIntake(id: "i-later", minutesAgo: 120),
                    taken,
                    future,
                    archivedMedIntake
                ],
                now: Self.now
            )

            #expect(options.due.map(\.id) == ["i-later", "i-late"], "earliest first, pending + past-due only")
            #expect(options.due.allSatisfy { $0.medication.id == Self.scheduledMed.id })
            #expect(!options.isEmpty)
        }

        // MARK: - 3) the machinery a PRN row will use (control)

        /// The ad-hoc record itself is not new: `logIntakeFree` posts to the
        /// medication's own intake route with the instant it is given and NO
        /// `scheduledFor` (the server defaults it to `takenAt`), and it
        /// invalidates the medication list so the card's "letzte Einnahme"
        /// reflects the write — 15-03's seam.
        @Test("Die Ad-hoc-Erfassung schreibt jetzt und frischt die Liste auf")
        @MainActor
        func adHocIntakeRecordsAtNowAndInvalidatesTheList() async throws {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let coordinator = SWRCoordinator(cache: cache, reachability: AlwaysOnline())
            try await cache.write(.medicationsList, payload: JSONEncoder.hlDefault.encode([Self.prn]))

            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = BodyRecorder()
            session.install { request in
                // Record the intake POST only: the store fires a compliance
                // refresh behind it, and that request is not what is asserted.
                if request.targets("/api/medications/med_prn_0001/intake", method: "POST") {
                    recorder.record(
                        path: request.url?.path ?? "",
                        body: BodyRecorder.body(of: request)
                    )
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"data":{"id":"ev-1","medicationId":"med_prn_0001","scheduledFor":"2023-11-14T22:13:20Z","takenAt":"2023-11-14T22:13:20Z","skipped":false,"snoozedUntil":null}}"#
                            .utf8
                    )
                )
            }
            let store = try Self.makeStore(session, swr: coordinator)

            let outcome = await store.logIntakeFree(
                medicationId: Self.prn.id,
                takenAt: Self.now,
                skipped: false
            )

            #expect(outcome == .success)
            #expect(recorder.path == "/api/medications/med_prn_0001/intake")
            #expect(recorder.body.contains("2023-11-14T22:13:20"), "the instant it was handed")
            #expect(!recorder.body.contains("scheduledFor"), "an ad-hoc dose pins no slot")
            let after: Cached<[Medication]>? = await cache.read(.medicationsList, as: [Medication].self)
            #expect(after == nil, "15-03's seam: the list is re-read after the write")
        }

        // MARK: - Harness

        final class BodyRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _path = ""
            private var _body = ""

            var path: String {
                lock.lock()
                defer { lock.unlock() }
                return _path
            }

            var body: String {
                lock.lock()
                defer { lock.unlock() }
                return _body
            }

            func record(path: String, body: String) {
                lock.lock()
                _path = path
                _body = body
                lock.unlock()
            }

            static func body(of request: URLRequest) -> String {
                let data = request.httpBody ?? request.httpBodyStream.map { stream in
                    stream.open()
                    defer { stream.close() }
                    var acc = Data()
                    let size = 4096
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                    defer { buffer.deallocate() }
                    while stream.hasBytesAvailable {
                        let read = stream.read(buffer, maxLength: size)
                        if read <= 0 { break }
                        acc.append(buffer, count: read)
                    }
                    return acc
                }
                return String(data: data ?? Data(), encoding: .utf8) ?? ""
            }
        }

        final class AlwaysOnline: ReachabilityProviding, @unchecked Sendable {
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
        static func makeStore(
            _ session: MockURLProtocolSession,
            swr: SWRCoordinator? = nil
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
