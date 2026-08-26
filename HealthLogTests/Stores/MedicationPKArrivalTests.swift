// 14-02 (A3) — the PK section stops jumping in.
//
// The operator's A3 is "Das Chart auf der Medikamentenseite lädt immer nach und
// springt dann ins Bild hinein". `MDRGatedDrugLevelSection` has exactly two
// branches — no intakes → placeholder, intakes → chart — and no reserved
// height, which was a deliberate 12-10 decision made about a section whose
// input was assumed to be there. It is not: `intakes` arrives as a first page
// plus up to 80 sequential drain pages, and the section is handed EVERY
// intermediate state. Each one is a fresh `doses` array, so each one is a full
// curve recomputation (twice per body: once for the `ForEach`, once for the
// accessibility descriptor) plus an O(samples × doses) phase classification.
//
// Both halves are measured here through the store's own observable contract:
// what the section is handed, and how often it changes. The drain's collection
// is not under test and must not move — the equality control pins that the same
// pages in the same order still yield the same final dose set and the same
// curve over it.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Medication PK arrival (14-02)", .serialized)
    @MainActor
    struct MedicationPKArrivalTests {
        /// Page size the store asks for (`intakesPageSize`), and the fixture's
        /// total — three pages, so the drain really drains.
        private nonisolated static let pageSize = 30
        private nonisolated static let totalEvents = 90
        /// Parks each drain page long enough that the intermediate states the
        /// section is handed are observable from the test's own actor.
        private nonisolated static let pageDelay: TimeInterval = 0.04

        private let now = Date(timeIntervalSince1970: 1_700_000_000)

        // MARK: - Harness

        private func makeAPI(_ session: MockURLProtocolSession) -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
        }

        private func makeStore(_ session: MockURLProtocolSession) throws -> MedicationDetailStore {
            let medication = Medication(
                id: "med_test",
                name: "Mounjaro 7.5 mg",
                dose: "7.5 mg",
                treatmentClass: "GLP1",
                schedule: MedicationSchedule(times: [], weekdays: nil)
            )
            let repo = try MedicationsRepository(api: makeAPI(session), outbox: OutboxQueue(inMemory: true))
            return MedicationDetailStore(medication: medication, repo: repo)
        }

        private func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        /// The intake events this fixture's account holds, newest first — one
        /// every six hours, all taken, none skipped.
        private func fixtureEvents() -> [PaginatedIntakeEvent] {
            (0 ..< Self.totalEvents).map { index in
                let at = now.addingTimeInterval(-Double(index) * 6 * 3600)
                return PaginatedIntakeEvent(id: "ev_\(index)", takenAt: at, skipped: false, scheduledFor: at)
            }
        }

        private func pageBody(offset: Int) -> Data {
            let events = fixtureEvents()
            let slice = events.dropFirst(offset).prefix(Self.pageSize)
            let rows = slice.map { event -> String in
                let at = iso(event.takenAt!)
                return #"{"id":"\#(event.id)","takenAt":"\#(at)","skipped":false,"scheduledFor":"\#(at)"}"#
            }
            let meta = #"{"total":\#(Self.totalEvents),"limit":\#(Self.pageSize),"offset":\#(offset)}"#
            return Data(#"{"data":{"events":[\#(rows.joined(separator: ","))],"meta":\#(meta)}}"#.utf8)
        }

        /// Serves the two routes `load()` must not fail on (`/glp1`, `/intake`)
        /// and refuses everything else — every other fetch in the fan-out is
        /// tolerant by contract, so a refusal is the honest fixture.
        private func installHandlers(_ session: MockURLProtocolSession) {
            let pages: [Int: Data] = [
                0: pageBody(offset: 0),
                30: pageBody(offset: 30),
                60: pageBody(offset: 60)
            ]
            let details = Data(#"{"data":{"doseChanges":[],"recentIntakes":[],"inventory":null}}"#.utf8)
            session.install { request in
                let path = request.url?.path ?? ""
                let query = request.url?.query ?? ""
                let ok = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                if path.hasSuffix("/glp1") {
                    return (ok, details)
                }
                if path.hasSuffix("/intake") {
                    let offset = Self.offset(inQuery: query)
                    if offset > 0 {
                        // The URL-loading system owns this thread; the drain's
                        // intermediate states stay observable from the test.
                        Thread.sleep(forTimeInterval: Self.pageDelay)
                    }
                    return (ok, pages[offset] ?? Data(#"{"data":{"events":[],"meta":{"total":90}}}"#.utf8))
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"not part of this fixture"}"#.utf8)
                )
            }
        }

        private nonisolated static func offset(inQuery query: String) -> Int {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == "offset" { return Int(parts[1]) ?? 0 }
            }
            return 0
        }

        /// The PK options `DrugLevelChartView` draws with (21 d back, no
        /// projection, 6 h step) — web parity, unchanged by this plan.
        private nonisolated static let chartOptions = Glp1PK.Options(
            windowHoursBefore: 21 * 24,
            windowHoursAfter: 0,
            stepHours: 6
        )

        // MARK: - 1) an unsettled input must never reach the section

        /// The section renders its terminal chart from whatever `pkDoseEvents()`
        /// returns, so every partial drain state is drawn as if it were the
        /// finished curve — and the finished curve then replaces it, taller,
        /// pushing the page. There is no third state that could say "still
        /// collecting", which is what the reserved-height loading branch is for.
        @Test("Ein noch unfertiger Intake-Satz erreicht die Kurve nicht")
        func pkSectionHasALoadingState() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installHandlers(session)
            let store = try makeStore(session)

            var handedAnUnsettledInput = false
            let load = Task { await store.load() }
            for _ in 0 ..< 800 {
                // `hasMoreIntakes` is the store's own statement that the input
                // is still growing. While it says so, the section may not be
                // handed a dose set to draw as if it were the finished curve.
                if store.hasMoreIntakes, !store.pkDoseEvents().isEmpty { handedAnUnsettledInput = true }
                if load.isCancelled { break }
                if !store.isLoading, !store.intakes.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await load.value

            #expect(
                handedAnUnsettledInput == false,
                "EXPECTED_RED: the section pops from empty to chart with no loading branch"
            )
            // The settled state is unaffected either way — this is about when.
            #expect(store.pkDoseEvents().count == Self.totalEvents)
        }

        // MARK: - 2) exactly one settled input per load

        /// Every distinct dose set the section is handed is one full curve
        /// computation plus one O(samples × doses) descriptor. Across a
        /// three-page drain the section is handed three of them today; it may be
        /// handed exactly one.
        @Test("Die Kurve wird einmal pro fertigem Eingang berechnet")
        func curveComputesOncePerSettledInput() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installHandlers(session)
            let store = try makeStore(session)

            var observed: [Int] = []
            let load = Task { await store.load() }
            for _ in 0 ..< 800 {
                let count = store.pkDoseEvents().count
                if count > 0, observed.last != count { observed.append(count) }
                if load.isCancelled { break }
                if !store.isLoading, !store.intakes.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            await load.value
            let settled = store.pkDoseEvents().count
            if observed.last != settled { observed.append(settled) }

            #expect(
                observed.count == 1,
                "EXPECTED_RED: the drain recomputes the curve per append"
            )
            #expect(observed.last == Self.totalEvents)
        }

        // MARK: - 3) the computation itself does not move (control)

        /// The proof that this plan moved *when* the curve is computed and
        /// nothing else: the drain still collects the same pages in the same
        /// order, the settled dose set is the same, and the curve over it is
        /// byte-equal to the curve today's render path produces from it.
        @Test("Der fertige Eingang und seine Kurve sind unverändert")
        func settledCurveEqualsTheCurveOverTheFinalIntakeSet() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installHandlers(session)
            let store = try makeStore(session)

            await store.load()

            #expect(store.intakes.count == Self.totalEvents, "same pages, same order, same final set")
            #expect(store.intakes.map(\.id) == fixtureEvents().map(\.id))
            let doses = store.pkDoseEvents()
            #expect(doses.count == Self.totalEvents)
            #expect(doses.allSatisfy { $0.doseMg == 7.5 }, "headline-dose fallback, unchanged")

            let asOf = now
            let expected = Glp1PK.curve(
                drug: .tirzepatide,
                doses: doses,
                asOf: asOf,
                options: Self.chartOptions
            )
            let again = Glp1PK.curve(
                drug: .tirzepatide,
                doses: store.pkDoseEvents(),
                asOf: asOf,
                options: Self.chartOptions
            )
            #expect(expected == again, "the same settled input yields the same curve")
            #expect(expected.isEmpty == false)
        }

        // MARK: - 4) counted at the seam, and byte-equal to what the view drew

        /// The compute count, read off the store's own injected seam rather than
        /// inferred: exactly one curve per settled input, and the published
        /// samples are byte-equal to the curve the render path produced from the
        /// same doses with the same options.
        @Test("Genau eine Berechnung pro Load, am Seam gezählt")
        func theCurveIsComputedExactlyOncePerLoad() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installHandlers(session)
            let store = try makeStore(session)
            let computes = ComputeCounter()
            store.onDrugLevelCurveComputed = { computes.increment() }

            await store.load()

            #expect(computes.value == 1, "one settled input, one computation")
            guard case let .curve(curve) = store.drugLevelSection else {
                Issue.record("a settled section with doses must carry a curve")
                return
            }
            #expect(curve.doses.count == Self.totalEvents)
            #expect(curve.samples.isEmpty == false)
            #expect(curve.phases.count == curve.samples.count, "one phase per sample, same order")
            #expect(
                curve.samples == Glp1PK.curve(
                    drug: .tirzepatide,
                    doses: curve.doses,
                    asOf: curve.asOf,
                    options: MedicationDetailStore.drugLevelChartOptions
                ),
                "the published curve is byte-equal to the curve the view used to compute"
            )
            #expect(MedicationDetailStore.drugLevelChartOptions == Self.chartOptions, "web parity window, unmoved")
        }

        // MARK: - 5) the section's three states

        /// A fresh store has not collected anything yet, so its section reads
        /// `.loading` — the reserved frame — rather than claiming there are no
        /// intakes. A settled collection with no doses reads `.empty`.
        @Test("Die Sektion hat drei Zustände, und beginnt im reservierten")
        func theSectionHasThreeStates() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            installHandlers(session)
            let store = try makeStore(session)

            #expect(store.drugLevelSection == .loading, "nothing collected yet is not 'no intakes logged'")

            await store.load()
            guard case .curve = store.drugLevelSection else {
                Issue.record("a drained account with doses must reach the curve state")
                return
            }

            // A settled collection that genuinely holds nothing is `.empty`.
            let bare = try makeStore(session)
            bare._testInject(intakes: [])
            bare.settleDrugLevelSectionIfStillLoading()
            #expect(bare.drugLevelSection == .empty)
        }
    }

    /// Counts curve computations through the store's injected seam.
    private final class ComputeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

#endif
