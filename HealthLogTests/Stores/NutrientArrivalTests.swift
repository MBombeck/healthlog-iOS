// 14-04 (F1) — nutrients the server already holds must reach the Ernährung screen.
//
// The operator sees a nutrient entry in Apple Health and in the web app, and
// nothing on iOS. Task 1 measured where the two clients diverge; the short
// version, with the evidence in 14-VALIDATION.md:
//
// - the server publishes exactly four nutrient routes at v1.37.24
//   (`/api/nutrients`, `/api/nutrients/batch`, `/api/nutrients/daily`,
//   `/api/nutrients/water`), so there is no route the web app can read that iOS
//   cannot — this is not a server gap and no ask is owed;
// - both catalogs carry the same 26 codes (macros deliberately excluded on both
//   sides), so nothing is dropped in decoding;
// - what differs is the WINDOW. `NutrientListScreen.reload()` calls
//   `NutrientStore.load()` with the server default of 14 days, and the server
//   omits every nutrient with no data inside the requested window. The web
//   app's nutrients surface gates on a 90-day window.
//
// So an account whose newest nutrient day is older than a fortnight shows an
// entry on the web and an empty state on iOS — and the empty state then says
// Apple Health has delivered nothing, which is the one thing that is not true.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("Nutrient arrival (14-04)", .serialized)
    @MainActor
    struct NutrientArrivalTests {
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

        private func makeStore(_ session: MockURLProtocolSession) throws -> NutrientStore {
            let repository = try NutrientReadRepository(
                api: makeAPI(session),
                outbox: OutboxQueue(inMemory: true)
            )
            return NutrientStore(repository: repository)
        }

        private nonisolated static func days(inQuery query: String) -> Int {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == "days" { return Int(parts[1]) ?? 0 }
            }
            return 0
        }

        /// The account this fixture models: one magnesium day-total, 30 days
        /// old. The server serves it for any window that reaches back far
        /// enough and omits it — as it omits every nutrient without data in the
        /// window — for anything shorter.
        private func install(
            _ session: MockURLProtocolSession,
            latestDayAgeInDays: Int,
            requestedWindows: WindowLog
        ) {
            session.install { request in
                let query = request.url?.query ?? ""
                let requested = Self.days(inQuery: query)
                requestedWindows.record(requested)
                let ok = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let carries = requested >= latestDayAgeInDays
                let rows = carries
                    ? #"{"nutrient":"magnesium","unit":"mg","latestDay":"2026-07-23","latestAmount":320.0,"daysWithData":3}"#
                    : ""
                let body = #"{"data":{"windowDays":\#(requested),"nutrients":[\#(rows)]}}"#
                return (ok, Data(body.utf8))
            }
        }

        // MARK: - 1) what the account holds must reach the screen

        @Test("Ein Nährstoff, den das Konto hält, erreicht den Ernährungs-Screen")
        func serverHeldNutrientsRender() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let windows = WindowLog()
            install(session, latestDayAgeInDays: 30, requestedWindows: windows)
            let store = try makeStore(session)

            // Exactly the call `NutrientListScreen.reload()` makes: no window
            // argument, because the screen has never had a reason to pick one.
            await store.load()

            #expect(
                store.rows.isEmpty == false,
                "EXPECTED_RED: data the account holds does not reach the Ernährung screen"
            )
            #expect(store.rows.first?.nutrient == .magnesium)
            #expect(store.lastError == nil)
            #expect(store.isDisabled == false)
            #expect(store.isLoading == false)
        }

        // MARK: - 2) the module gate keeps its own dedicated state (control)

        @Test("Ein abgeschaltetes Modul behält seinen eigenen Zustand")
        func disabledModuleKeepsItsDedicatedState() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            session.install { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"module.disabled"}"#.utf8)
                )
            }
            let store = try makeStore(session)

            await store.load()

            #expect(store.isDisabled)
            #expect(store.lastError == nil, "a switched-off module is not an error")
            #expect(store.rows.isEmpty)
            #expect(store.isLoading == false)
            #expect(
                NutrientEmptyState.resolve(isModuleEnabled: false, isPreparingHealthKitAccess: false) == .moduleOff
            )
        }

        // MARK: - 3) a genuinely empty account renders the honest empty state (control)

        @Test("Ein wirklich leeres Konto bekommt den ehrlichen Leerzustand")
        func genuinelyEmptyAccountRendersTheHonestEmptyState() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let windows = WindowLog()
            // No window reaches it, because there is nothing to reach.
            install(session, latestDayAgeInDays: 100_000, requestedWindows: windows)
            let store = try makeStore(session)

            await store.load()

            #expect(store.rows.isEmpty)
            #expect(store.lastError == nil)
            #expect(store.isDisabled == false)
            #expect(store.isLoading == false)
            #expect(
                NutrientEmptyState.resolve(isModuleEnabled: true, isPreparingHealthKitAccess: false) == .noData
            )
            // The window is a fact the empty state can name, because the server
            // echoed which one it used.
            #expect(store.windowDays == NutrientStore.overviewWindowDays)
        }

        // MARK: - 4) the window the screen asks for (control)

        @Test("Der Screen fragt das Fenster, auf das die Web-App gatet")
        func theScreenAsksForTheWebsOwnWindow() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let windows = WindowLog()
            install(session, latestDayAgeInDays: 30, requestedWindows: windows)
            let store = try makeStore(session)

            await store.load()

            #expect(windows.requested == [NutrientStore.overviewWindowDays])
            #expect(NutrientStore.overviewWindowDays == 90, "the web's own nutrients data gate")
            #expect(NutrientStore.serverDefaultWindowDays == 14, "and the server's default, unchanged")
        }

        // MARK: - 5) a server that refuses the window degrades, never errors

        /// The `days` ceiling of `/api/nutrients` is not in the contract
        /// evidence available offline, so a deployment that validates it more
        /// tightly must not turn today's empty screen into an error screen.
        @Test("Ein abgelehntes Fenster fällt einmal auf den Server-Default zurück")
        func aRefusedWindowFallsBackOnceToTheServerDefault() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let windows = WindowLog()
            session.install { request in
                let query = request.url?.query ?? ""
                let requested = Self.days(inQuery: query)
                windows.record(requested)
                if requested > NutrientStore.serverDefaultWindowDays {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"data":null,"error":"days out of range"}"#.utf8)
                    )
                }
                let ok = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let row = #"{"nutrient":"water","unit":"ml","latestDay":"2026-08-21","latestAmount":1500.0,"daysWithData":9}"#
                return (ok, Data(#"{"data":{"windowDays":14,"nutrients":[\#(row)]}}"#.utf8))
            }
            let store = try makeStore(session)

            await store.load()

            #expect(windows.requested == [NutrientStore.overviewWindowDays, NutrientStore.serverDefaultWindowDays])
            #expect(store.rows.count == 1, "the fallback read still renders")
            #expect(store.lastError == nil, "a refused window is not an error the reader has to see")
            #expect(store.windowDays == 14, "and the empty state would name the window that was actually used")
            #expect(store.isDisabled == false)
        }

        /// The module gate is NOT a window rejection and must never be retried
        /// as one.
        @Test("Das Modul-Gate ist keine Fenster-Ablehnung")
        func theModuleGateIsNotAWindowRejection() {
            #expect(NutrientStore.isWindowRejection(.server(status: 403, code: "module.disabled", message: "")) == false)
            #expect(NutrientStore.isWindowRejection(.server(status: 500, code: nil, message: "")) == false)
            #expect(NutrientStore.isWindowRejection(.server(status: 400, code: nil, message: "")))
            #expect(NutrientStore.isWindowRejection(.server(status: 422, code: nil, message: "")))
        }
    }

    /// Records every `days` window the store asked the server for.
    final class WindowLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []

        func record(_ days: Int) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(days)
        }

        var requested: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

#endif
