// 15-01 (B1) — a history entry can be marked taken, but its time cannot be
// corrected.
//
// The operator's B1 is "eine Einnahme lässt sich als genommen markieren, aber
// die Uhrzeit nicht bearbeiten". The wire half is not the gap: the deployed
// contract's `updateIntakeEventSchema` carries `takenAt`, `MedicationsRepository`
// models it (`IntakePatch.takenAt`, `PUT /api/medications/{id}/intake/{eventId}`),
// and `IntakeHistoryRow.swift:13` even documents an "Edit access" affordance.
//
// What is missing is the store's half of an edit: `updateIntake` fires the PUT
// and only then swaps in whatever the server answered. For a mark that is
// invisible — the detail screen patches its own row first. For a *time
// correction* it is the whole interaction: the row the user is looking at keeps
// the wrong time for the length of the round-trip, and if the round-trip fails
// there is nothing to roll back because nothing was ever applied.
//
// Both halves are measured here through what the store already publishes
// (`todayIntakes`), against the API that already exists, over a session-scoped
// MockURLProtocol with the real `APIClient`. The in-flight window is made
// observable by parking the handler; the response flag closes the window, so
// the optimistic observation can never be satisfied by the server's own row.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Intake history — the time is editable (15-01)", .serialized)
    @MainActor
    struct IntakeHistoryEditTests {
        // MARK: - Fixture

        /// 2023-11-14 22:13:20Z — a fixed instant well inside the server's
        /// five-year `takenAt` plausibility floor and safely in the past.
        private nonisolated static let scheduled = Date(timeIntervalSince1970: 1_700_000_000)
        /// The correction the operator makes: "I took it at 23:48, not 22:13".
        private nonisolated static let corrected = scheduled.addingTimeInterval(95 * 60)

        private nonisolated static let medicationID = "med-1"
        private nonisolated static let eventID = "intake-1"

        private var seededRow: MedicationIntake {
            MedicationIntake(
                id: Self.eventID,
                medicationId: Self.medicationID,
                scheduledAt: Self.scheduled,
                takenAt: Self.scheduled,
                status: .taken,
                snoozedUntil: nil
            )
        }

        /// Handler-side bookkeeping. The handler runs on a URLSession thread,
        /// so every field is lock-guarded.
        private final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _body: String = ""
            private var _responded = false
            private var _calls = 0

            var body: String {
                lock.lock()
                defer { lock.unlock() }
                return _body
            }

            var responded: Bool {
                lock.lock()
                defer { lock.unlock() }
                return _responded
            }

            var calls: Int {
                lock.lock()
                defer { lock.unlock() }
                return _calls
            }

            func record(body: String) {
                lock.lock()
                _body = body
                _calls += 1
                lock.unlock()
            }

            func didRespond() {
                lock.lock()
                _responded = true
                lock.unlock()
            }
        }

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

        private func makeStore(_ session: MockURLProtocolSession) throws -> MedicationsStore {
            let repo = try MedicationsRepository(
                api: makeAPI(session),
                outbox: OutboxQueue(inMemory: true)
            )
            let store = MedicationsStore(repo: repo)
            store._testForceSet(todayIntakes: [seededRow])
            return store
        }

        /// Response shape (the decoder accepts fractional + plain).
        private nonisolated static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        /// Request shape — `APIClient`'s encoder is `.iso8601`, i.e. NO
        /// fractional seconds. Wire assertions must read the body in the
        /// spelling the client actually writes.
        private nonisolated static func wireISO(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }

        /// URLProtocol moves `httpBody` onto `httpBodyStream`; re-materialize either.
        private nonisolated static func body(of request: URLRequest) -> String {
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

        /// Parks the answer long enough that the in-flight window is observable
        /// from the test's own actor, then answers with `status` + `json`.
        private func installIntakeHandler(
            _ session: MockURLProtocolSession,
            recorder: Recorder,
            park: TimeInterval,
            status: Int,
            json: @escaping @Sendable () -> String
        ) {
            let route = "/api/medications/\(Self.medicationID)/intake/\(Self.eventID)"
            session.install { request in
                guard request.targets(route) else {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"not part of this fixture"}"#.utf8)
                    )
                }
                recorder.record(body: Self.body(of: request))
                Thread.sleep(forTimeInterval: park)
                recorder.didRespond()
                return (
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(json().utf8)
                )
            }
        }

        private nonisolated static func intakeJSON(takenAt: Date?) -> String {
            let taken = takenAt.map { "\"\(iso($0))\"" } ?? "null"
            return """
            {"data":{"id":"\(eventID)","medicationId":"\(medicationID)",\
            "scheduledFor":"\(iso(scheduled))","takenAt":\(taken),\
            "skipped":false,"snoozedUntil":null}}
            """
        }

        /// Watches the published row for `expected` for as long as the request
        /// is genuinely in flight. `recorder.responded` closes the window before
        /// the server's own row can land, so a `true` here can only ever mean
        /// the store applied the edit locally.
        private func sawWhileInFlight(
            store: MedicationsStore,
            recorder: Recorder,
            expected: Date
        ) async -> Bool {
            for _ in 0 ..< 600 {
                if recorder.responded { return false }
                if store.todayIntakes.first?.takenAt == expected { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }

        // MARK: - 1) the time is editable

        /// The correction the operator makes on the history row: same event,
        /// same status, a different `takenAt`. The PUT carries it today (the
        /// contract was never the gap); the row he is looking at does not.
        @Test("Die Uhrzeit eines Verlaufseintrags ist bearbeitbar")
        func takenAtIsEditable() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            installIntakeHandler(session, recorder: recorder, park: 0.25, status: 200) {
                Self.intakeJSON(takenAt: Self.corrected)
            }
            let store = try makeStore(session)

            let write = Task {
                await store.updateIntake(
                    medicationId: Self.medicationID,
                    eventId: Self.eventID,
                    patch: .init(takenAt: Self.corrected, skipped: false)
                )
            }
            let sawOptimisticEdit = await sawWhileInFlight(
                store: store,
                recorder: recorder,
                expected: Self.corrected
            )
            let outcome = await write.value

            #expect(
                sawOptimisticEdit,
                "EXPECTED_RED: the history offers mark and delete but no time edit"
            )
            // The wire half already works — this is the half B1 does not need.
            #expect(recorder.body.contains(Self.wireISO(Self.corrected)), "the PUT carries the corrected instant")
            #expect(outcome == .success)
            #expect(store.todayIntakes.first?.takenAt == Self.corrected)
        }

        // MARK: - 2) a rejected edit is taken back

        /// The other half of the same contract: what the row shows while the
        /// PUT is in flight has to be given back byte-for-byte when the server
        /// refuses it, and the refusal has to be stated. There is nothing to
        /// take back today, because nothing was ever put forward.
        @Test("Eine abgelehnte Korrektur wird vollständig zurückgenommen")
        func failedEditRollsBack() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            installIntakeHandler(session, recorder: recorder, park: 0.25, status: 422) {
                #"{"data":null,"error":{"code":"medications.intake.taken_at.out_of_range","message":"bad"}}"#
            }
            let store = try makeStore(session)
            let original = seededRow

            let write = Task {
                await store.updateIntake(
                    medicationId: Self.medicationID,
                    eventId: Self.eventID,
                    patch: .init(takenAt: Self.corrected, skipped: false)
                )
            }
            let sawOptimisticEdit = await sawWhileInFlight(
                store: store,
                recorder: recorder,
                expected: Self.corrected
            )
            let outcome = await write.value

            #expect(
                sawOptimisticEdit,
                "EXPECTED_RED: no edit path exists to roll back"
            )
            if case .failed = outcome {} else {
                Issue.record("a 422 on the edit path must be .failed, was \(outcome)")
            }
            #expect(store.todayIntakes.first == original, "the row is restored byte-identical")
            #expect(store.error != nil, "the refusal is stated")
        }

        // MARK: - 2b) the edit says only what it means

        /// The entry point the history row uses. A time correction is not a
        /// status change: the body carries `takenAt` and nothing else, so a row
        /// the server holds as taken stays taken and one it holds as skipped is
        /// not silently converted.
        @Test("Die Korrektur schickt nur den Zeitpunkt")
        func editSendsTakenAtAlone() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            installIntakeHandler(session, recorder: recorder, park: 0, status: 200) {
                Self.intakeJSON(takenAt: Self.corrected)
            }
            let store = try makeStore(session)

            let outcome = await store.editIntakeTakenAt(
                medicationId: Self.medicationID,
                eventId: Self.eventID,
                takenAt: Self.corrected,
                now: Self.corrected.addingTimeInterval(3600)
            )

            #expect(outcome == .success)
            #expect(recorder.calls == 1)
            #expect(recorder.body.contains(Self.wireISO(Self.corrected)))
            #expect(!recorder.body.contains("skipped"), "a time correction states no status")
            #expect(!recorder.body.contains("status"))
            #expect(store.todayIntakes.first?.takenAt == Self.corrected)
            #expect(store.todayIntakes.first?.status == .taken, "the row stays taken")
        }

        /// The server's own plausibility bounds (v1.15.19: no future instant
        /// beyond five minutes of skew, nothing older than five years) are
        /// mirrored locally, so an impossible correction costs no round-trip
        /// and reads the same copy the server would have sent back.
        @Test("Eine unmögliche Uhrzeit kostet keine Runde")
        func impossibleTimeIsRefusedLocally() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            installIntakeHandler(session, recorder: recorder, park: 0, status: 200) {
                Self.intakeJSON(takenAt: Self.corrected)
            }
            let store = try makeStore(session)
            let original = seededRow

            let future = await store.editIntakeTakenAt(
                medicationId: Self.medicationID,
                eventId: Self.eventID,
                takenAt: Self.corrected.addingTimeInterval(3600),
                now: Self.corrected
            )
            let ancient = await store.editIntakeTakenAt(
                medicationId: Self.medicationID,
                eventId: Self.eventID,
                takenAt: Self.corrected.addingTimeInterval(-MedicationsStore.takenAtMaxAge - 60),
                now: Self.corrected
            )

            if case let .failed(.server(status, code, _)) = future {
                #expect(status == 422)
                #expect(code == "medications.intake.taken_at.out_of_range")
            } else {
                Issue.record("a future takenAt must be refused locally, was \(future)")
            }
            if case .failed = ancient {} else {
                Issue.record("a takenAt older than five years must be refused locally, was \(ancient)")
            }
            #expect(recorder.calls == 0, "neither refusal reached the network")
            #expect(store.todayIntakes.first == original, "and neither touched the row")
        }

        // MARK: - 3) mark-taken is unchanged (control)

        /// B1 adds an edit; it does not re-open the retro-mark contract. The
        /// v0.14.8 body shape (`skipped` boolean, `takenAt` at the scheduled
        /// instant) and the `.success` outcome stay exactly as they are.
        @Test("Als genommen markieren verhält sich unverändert")
        func markTakenIsUnchanged() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            installIntakeHandler(session, recorder: recorder, park: 0, status: 200) {
                Self.intakeJSON(takenAt: Self.scheduled)
            }
            let store = try makeStore(session)

            let outcome = await store.markIntakeRetroactively(
                medicationId: Self.medicationID,
                eventId: Self.eventID,
                status: .taken,
                scheduledAt: Self.scheduled,
                now: Self.scheduled.addingTimeInterval(3600)
            )

            #expect(outcome == .success)
            #expect(recorder.calls == 1)
            #expect(recorder.body.contains("\"skipped\":false"))
            #expect(recorder.body.contains(Self.wireISO(Self.scheduled)))
            #expect(store.todayIntakes.first?.takenAt == Self.scheduled)
            #expect(store.todayIntakes.first?.status == .taken)
        }

        // MARK: - 4) delete is unchanged (control)

        /// The v0.14.8 delete-everywhere brief is not re-litigated here: the
        /// row still leaves the published list on a 204.
        @Test("Löschen verhält sich unverändert")
        func deleteIsUnchanged() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let recorder = Recorder()
            let route = "/api/medications/\(Self.medicationID)/intake/\(Self.eventID)"
            session.install { request in
                guard request.targets(route) else {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"not part of this fixture"}"#.utf8)
                    )
                }
                recorder.record(body: Self.body(of: request))
                recorder.didRespond()
                // The route answers 204 on the wire. A bare 204 with an EMPTY
                // body cannot be decoded by `APIClient.decodePayload` (neither
                // the envelope nor the raw `EmptyResponse` parse from zero
                // bytes) — noted as a diagnosis in the phase's deferred items;
                // it is not this plan's to fix and not what this control is
                // about. The envelope below is the shape the delete path is
                // exercised with everywhere else.
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null}"#.utf8)
                )
            }
            let store = try makeStore(session)

            let outcome = await store.deleteIntake(medicationId: Self.medicationID, eventId: Self.eventID)

            #expect(outcome == .success)
            #expect(store.todayIntakes.isEmpty)
        }
    }

#endif

// swiftlint:enable force_unwrapping
