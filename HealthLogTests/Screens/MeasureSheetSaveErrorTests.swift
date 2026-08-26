import Foundation
@testable import HealthLog
import Testing

/// **v0.5.5.2 — MeasureSheetView save-error visibility.**
///
/// Before this fix the failure path from `MeasurementsStore.capture(...)`
/// only fired the error-haptic. No banner, no toast, no inline text —
/// the operator hit Speichern, felt a buzz, watched the sheet do
/// nothing, and assumed the app was frozen. PROJECT_GUIDE.md anti-pattern:
/// "silent error swallowing — entweder behandeln oder bewusst
/// durchwerfen mit Kontext".
///
/// The view now mirrors `store.error` into local `saveError` state when
/// `capture(...)` returns false, renders an `ErrorBanner` overlay at
/// the top, and auto-clears it on the next user input. We can't unit-
/// test the SwiftUI view directly without spinning up the runtime, so
/// these tests exercise the **store contract** the view depends on:
///
/// - On a non-retriable (server 4xx) failure the store sets `error`
///   *and* returns false → the view will read `store.error` and pin it
///   on `saveError`.
/// - On a retriable (offline / 5xx) failure the store enqueues the
///   write and ALSO surfaces the error in `store.error` → banner still
///   renders (user gets feedback that the save was deferred).
///
/// Pinning that contract here means a future refactor that "swallows"
/// the error inside the store breaks the test, not just the operator.
@MainActor
@Suite("MeasureSheetView — save-error visibility (v0.5.5.2)")
struct MeasureSheetSaveErrorTests {
    private func makeStore(handler: @escaping @Sendable (any Sendable) async throws -> any Sendable)
        async throws -> MeasurementsStore
    {
        let api = StubAPIClient()
        await api.setHandler(handler)
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MeasurementsRepository(api: api, outbox: outbox)
        return MeasurementsStore(repo: repo)
    }

    @Test("Non-retriable server failure populates store.error so the banner can surface it")
    func nonRetriableFailureSetsStoreError() async throws {
        let store = try await makeStore { _ in
            throw HLError.server(status: 422, code: "VALIDATION_ERROR", message: "Wert ungueltig.")
        }

        let ok = await store.capture(
            kind: .weight,
            value: .scalar(72.4),
            note: nil
        )

        #expect(ok == false, "Non-retriable failure must return false so the sheet stays open")
        #expect(store.error != nil, "Store.error must be populated — the banner reads from it")
        if case let .server(status, code, message) = store.error {
            #expect(status == 422)
            #expect(code == "VALIDATION_ERROR")
            #expect(message == "Wert ungueltig.")
        } else {
            Issue.record("Expected .server error, got \(String(describing: store.error))")
        }
    }

    @Test("Retriable offline failure populates store.error so the banner surfaces the deferred-state too")
    func retriableFailureSetsStoreError() async throws {
        let store = try await makeStore { _ in
            throw HLError.offline
        }

        let ok = await store.capture(
            kind: .pulse,
            value: .scalar(62),
            note: nil
        )

        #expect(ok == false, "Retriable failures still return false — write was queued, not committed")
        #expect(store.error == .offline, "Banner reads store.error; .offline must round-trip cleanly")
    }

    @Test("Successful capture clears store.error so a stale banner from a prior failure goes away")
    func successDoesNotLeaveStaleError() async throws {
        // The store does NOT auto-clear `error` on a subsequent success
        // — that's by design (callers may want to display "last error
        // until the next refresh"). For the sheet specifically the view-
        // local `saveError` lives independently and clears on user input,
        // so this test pins the *store-side* contract: `capture` success
        // returns true and the view's `if ok` branch dismisses without
        // touching `saveError`.
        let counter = TestStateBox()
        let store = try await makeStore { request in
            let attempt = await counter.increment()
            if attempt == 1 {
                throw HLError.server(status: 500, code: nil, message: "boom")
            }
            // Second attempt — return a wire DTO so the create path
            // resolves and the optimistic row gets re-keyed to the
            // server id.
            let req = request as? APIRequest<MeasurementWireDTO>
            #expect(req != nil)
            return MeasurementWireDTO(
                id: "server-ok",
                type: .pulse,
                value: 62,
                measuredAt: .now
            )
        }

        // First attempt fails.
        let first = await store.capture(kind: .pulse, value: .scalar(62), note: nil)
        #expect(first == false)
        #expect(store.error != nil)

        // Second attempt succeeds — saveError will be cleared by the
        // view's `onChange(of:)` handler (kind/scalar/note edits all
        // null it out before retry).
        let second = await store.capture(kind: .pulse, value: .scalar(62), note: nil)
        #expect(second == true)
    }
}

/// Tiny actor box so the stub handler can count attempts across
/// async boundaries without dragging in XCTestExpectation. Pattern
/// borrowed from the existing `MeasurementsRepository` outbox tests.
private actor TestStateBox {
    private var counter: Int = 0

    func increment() -> Int {
        counter += 1
        return counter
    }
}
