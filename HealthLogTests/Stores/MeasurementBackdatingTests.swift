// Diese Suite testet App-Target-Symbole (`MeasurementsStore`), die in der
// SPM-Library nicht enthalten sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Build 1 / item 1.4b — backdating a manual capture.**
    ///
    /// `MeasurementsStore+QuickCapture` hard-coded `recordedAt: .now`, and
    /// `MeasureSheetView` had no `DatePicker` at all, so the only way to log
    /// yesterday's weigh-in was save-then-edit. Web has carried the field plus an
    /// explicit hint since `measurement-form.tsx:539-560` — the hint exists
    /// because users kept missing that the field was adjustable.
    ///
    /// These pin (1) that the operator's instant reaches the optimistic row and
    /// the wire DTO, (2) that the default is still `.now` so the watch
    /// quick-capture and every other caller are unchanged, and (3) that a
    /// backdated row lands at its chronological position in `recent` rather than
    /// claiming to be the newest reading.
    @Suite("MeasurementsStore — backdated capture (item 1.4b)")
    @MainActor
    struct MeasurementBackdatingTests {
        private func makeStore() async throws -> MeasurementsStore {
            let api = StubAPIClient()
            await api.setHandler { _ in
                MeasurementWireDTO(
                    id: "server-1",
                    type: .weight,
                    value: 81.0,
                    measuredAt: .now,
                    source: .manual
                )
            }
            let outbox = try OutboxQueue(inMemory: true)
            let repo = MeasurementsRepository(api: api, outbox: outbox)
            return MeasurementsStore(repo: repo, healthKit: nil, isStandalone: { false })
        }

        @Test("A backdated capture stores the operator's instant, not .now")
        func backdatedCaptureKeepsItsInstant() async throws {
            let store = try await makeStore()
            let yesterday = Date.now.addingTimeInterval(-86400)

            let ok = await store.capture(
                kind: .weight,
                value: .scalar(81.0),
                note: nil,
                recordedAt: yesterday
            )

            #expect(ok)
            let row = try #require(store.recent.first { $0.kind == .weight })
            #expect(
                abs(row.recordedAt.timeIntervalSince(yesterday)) < 1,
                "the capture must carry the operator's timestamp through to the stored row"
            )
        }

        @Test("Omitting recordedAt still defaults to now — existing callers unchanged")
        func defaultIsStillNow() async throws {
            let store = try await makeStore()
            let before = Date.now

            let ok = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)

            #expect(ok)
            let row = try #require(store.recent.first { $0.kind == .weight })
            #expect(row.recordedAt >= before.addingTimeInterval(-1))
            #expect(row.recordedAt <= Date.now.addingTimeInterval(1))
        }

        @Test("A backdated row lands at its chronological position, not at the top")
        func backdatedRowSortsChronologically() async throws {
            let store = try await makeStore()

            // Log "now" first, then backdate a second capture to yesterday. The
            // backdated one must NOT sit above the newer reading.
            _ = await store.capture(kind: .weight, value: .scalar(81.0), note: nil)
            _ = await store.capture(
                kind: .weight,
                value: .scalar(80.0),
                note: nil,
                recordedAt: Date.now.addingTimeInterval(-86400)
            )

            let dates = store.recent.map(\.recordedAt)
            #expect(
                dates == dates.sorted(by: >),
                "`recent` is newest-first; a backdated capture must not jump the queue"
            )
        }

        @Test("The wire DTO carries the backdated instant as measuredAt")
        func wireDTOCarriesBackdatedInstant() throws {
            let yesterday = Date.now.addingTimeInterval(-86400)
            let measurement = Measurement(
                id: "local-1",
                kind: .weight,
                recordedAt: yesterday,
                value: .scalar(81.0),
                note: nil,
                source: .manual
            )
            let dto = try #require(measurement.toCreateDTOs().first)
            #expect(dto.measuredAt == yesterday, "backdating that stops at the store is not backdating")
        }

        @Test("Blood pressure backdates both fanned-out rows to the same instant")
        func bloodPressureBackdatesBothRows() {
            let yesterday = Date.now.addingTimeInterval(-86400)
            let measurement = Measurement(
                id: "local-bp",
                kind: .bloodPressure,
                recordedAt: yesterday,
                value: .bloodPressure(systolic: 120, diastolic: 80),
                note: nil,
                source: .manual
            )
            let dtos = measurement.toCreateDTOs()
            #expect(dtos.count == 2)
            for dto in dtos {
                #expect(dto.measuredAt == yesterday, "sys + dia must share one timestamp")
            }
        }
    }

#endif
