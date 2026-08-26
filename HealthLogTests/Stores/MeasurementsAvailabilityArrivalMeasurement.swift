// 20-01 — the R4 separation, as a machine-run measurement.
//
// R4 ("in den Insights fehlen die meisten Abschnitte") reduces to a single
// fact, pinned in `InsightsEmptyAvailabilityCompositionTests`: `availableKinds`
// was empty. Two explanations were live and were deliberately NOT collapsed:
//
//   (A) congestion — the availability load is still in flight;
//   (B) never completes — `loadAvailability()` throws at
//       `MeasurementsStore+Availability.swift:22`, or `load()` is refused.
//
// The plan's device-side form of the check was "pull to refresh, wait past
// 60 s, watch the console for `store-effect-refused store=measurements`". This
// harness performs that check on the simulator instead, over REAL sockets to
// `scripts/latency-proxy.py` on the host — real `URLSession`, real `APIClient`,
// real `SWRCache` (the serial `@ModelActor` that is Phase 21's subject), real
// `MeasurementsStore`. Nothing about the store is faked; only the wire is ours.
//
// **How to run it.** It is inert without an origin, on purpose: the permanent
// suite must not depend on a process the runner has to remember to start. With
// `HL_R4_ORIGIN` absent every case below is a trivially-true statement about an
// absent instrument, and that is stated here rather than hidden. To take the
// measurement:
//
//     scripts/latency-proxy.py --seed scripts/fixtures/r4-availability-seed.json \
//         --port 8787 --delay 0 &
//     HL_R4_ORIGIN=http://127.0.0.1:8787 \
//       xcodebuild -project HealthLog.xcodeproj -scheme HealthLog test \
//       -only-testing:HealthLogTests/MeasurementsAvailabilityArrivalMeasurement
//
// and again with `--delay 5` for the congested row. The captured rows are
// transcribed into `.planning/active/v1-submission/R4-ANSWER.md`.
//
// **What was already established by reading, before any run** — and what the
// run is therefore designed to test:
//
//   1. `loadAvailability()` has exactly ONE call site in the whole app: the
//      `.task { await measurementsStore.loadAvailability() }` on
//      `InsightsContainerScreen.swift:198`. A SwiftUI `.task` runs once per view
//      identity and is cancelled when the view leaves the hierarchy.
//   2. `InsightsScreen`'s `refreshable` block — whose own comment reads "if you
//      add a card here that reads from a new store, ADD ITS LOAD HERE TOO.
//      Otherwise pull-to-refresh feels half-broken" — does NOT call
//      `loadAvailability()`. Pull-to-refresh cannot re-drive availability.
//   3. `loadAvailability()` records NO refusal on any exit: the nil-lease exit
//      returns bare, and the `catch` writes an `HLLog.api.info` line and
//      nothing else. So `store-effect-refused store=measurements` — the very
//      line the device-side check was to look for — CANNOT be emitted by this
//      leg at all, and its absence proves nothing about it.
//
// Together those say (A) and (B) need not be rivals: congestion alone is
// sufficient to make availability permanently absent, silently, with no
// user-reachable repair. The measurement's job is to make that a recorded
// observation instead of an argument.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("R4 availability-arrival measurement (20-01)", .serialized)
    @MainActor
    struct MeasurementsAvailabilityArrivalMeasurement {
        private final class StubReach: ReachabilityProviding, @unchecked Sendable {
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

        private final class RefusalLog: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []

            func append(_ line: String) {
                lock.lock()
                defer { lock.unlock() }
                storage.append(line)
            }

            var lines: [String] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        private nonisolated static let owner = "r4-measurement-owner"

        /// The localhost origin `scripts/latency-proxy.py` is serving, or `nil`
        /// when no measurement is being taken.
        private nonisolated static var origin: URL? {
            guard let raw = ProcessInfo.processInfo.environment["HL_R4_ORIGIN"],
                  !raw.isEmpty else { return nil }
            return URL(string: raw)
        }

        /// The dwell the operator's Insights container gets before its `.task`
        /// is cancelled, in milliseconds. Default 800 ms — a short visit.
        private nonisolated static var dwellMilliseconds: UInt64 {
            guard let raw = ProcessInfo.processInfo.environment["HL_R4_DWELL_MS"],
                  let parsed = UInt64(raw) else { return 800 }
            return parsed
        }

        /// A label written into every recorded row so the healthy and congested
        /// runs are distinguishable in the archived gate log.
        private nonisolated static var runLabel: String {
            ProcessInfo.processInfo.environment["HL_R4_LABEL"] ?? "unlabelled"
        }

        private func makeStore(origin: URL) throws -> (MeasurementsStore, AuthenticatedSessionLeaseRegistry) {
            let keychain = InMemoryKeychain()
            try? keychain.setString("r4-measurement-token", forKey: KeychainKey.authToken)
            let environment = AppEnvironment(
                baseURL: origin,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            let api = APIClient(environment: environment, keychain: keychain)
            let swr = try SWRCoordinator(
                cache: SWRCache(modelContainer: SWRCache.makeInMemory()),
                reachability: StubReach()
            )
            let store = try MeasurementsStore(
                repo: MeasurementsRepository(
                    api: api,
                    outbox: OutboxQueue(inMemory: true),
                    swr: swr
                ),
                swr: swr,
                userIDProvider: { Self.owner }
            )
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            store.bindAuthenticatedSessionRegistry(registry)
            return (store, registry)
        }

        private nonisolated func record(_ row: String) {
            print("R4-MEASUREMENT [\(Self.runLabel)] \(row)")
        }

        /// The whole decision table, in one walk, so the healthy and congested
        /// runs produce directly comparable rows.
        @Test("Die Verfügbarkeits-Ankunft, gemessen statt vermutet")
        func availabilityArrivalUnderTheConfiguredWire() async throws {
            guard let origin = Self.origin else {
                record("SKIPPED — HL_R4_ORIGIN unset; no instrument, no claim")
                return
            }
            record("origin=\(origin.absoluteString) dwell=\(Self.dwellMilliseconds)ms")

            let observed = RefusalLog()
            StoreEffectDiagnostics.sink = { line in observed.append(line) }
            defer { StoreEffectDiagnostics.sink = nil }

            // ── Row 1 — the uninterrupted read. Does a working server produce
            //    availability at all, and how long does it take?
            let (control, _) = try makeStore(origin: origin)
            let started = Date()
            await control.loadAvailability()
            let elapsed = Date().timeIntervalSince(started)
            record(String(
                format: "row1 uninterrupted: kinds=%d elapsed=%.3fs refusals=%d",
                control.availableKinds.count,
                elapsed,
                observed.lines.count
            ))
            #expect(
                !control.availableKinds.isEmpty,
                "the instrument itself is broken if a healthy origin publishes no availability"
            )

            // ── Row 2 — the same read, cancelled at the dwell the container's
            //    `.task` actually gets. This is what a slow wire produces on a
            //    surface the operator swipes away from.
            let (interrupted, _) = try makeStore(origin: origin)
            let dwell = Self.dwellMilliseconds
            let task = Task { @MainActor in await interrupted.loadAvailability() }
            try? await Task.sleep(for: .milliseconds(dwell))
            task.cancel()
            _ = await task.value
            let afterCancel = observed.lines.count
            record(String(
                format: "row2 cancelled-at-dwell: kinds=%d refusals-total=%d",
                interrupted.availableKinds.count,
                afterCancel
            ))

            // ── Row 3 — the repair the operator actually has. This is exactly
            //    what `InsightsScreen`'s `refreshable` block runs for the
            //    measurements legs.
            //
            //    **22-01 changed this row's leg set, because it changed the
            //    block.** Before 22-01 the block called only `load(force:)`
            //    and this row mirrored that omission deliberately; the shipped
            //    block now also calls `loadAvailability()`, so the faithful
            //    mirror carries both legs. The mirror cannot drift back into
            //    fiction: `InsightsAvailabilityRefreshTests` pins the call in
            //    `InsightsScreen.swift`'s SOURCE TEXT, so a harness that models
            //    a leg the real closure does not have goes red.
            async let pulledRecent: Void = interrupted.load(force: true)
            async let pulledAvailability: Bool = interrupted.loadAvailability()
            _ = await (pulledRecent, pulledAvailability)
            let refusalsAfterPull = observed.lines.filter { $0.contains("store=measurements") }
            record(String(
                format: "row3 after-pull-to-refresh: kinds=%d recent=%d measurements-refusals=%d",
                interrupted.availableKinds.count,
                interrupted.recent.count,
                refusalsAfterPull.count
            ))
            for line in observed.lines {
                record("refusal-line: \(line)")
            }

            // ── Row 4 — the composition the two rows above produce, resolved
            //    through the very function the strip uses. This is the
            //    operator's screen, expressed as data.
            let composition = InsightsTabSelection.ordered(
                layout: .default,
                availableKinds: interrupted.availableKinds
                    .union(interrupted.recent.map(\.kind)),
                availableSpecials: [.recovery, .workouts, .mood, .ecg]
            )
            record("row4 composition-after-pull: \(composition.map(\.title).joined(separator: " · "))")

            await recordRepairAndPresentationRows(on: interrupted)
        }

        /// Rows 5 and 6, split out only because the walk exceeded
        /// `function_body_length` — a measurement is not worth new lint debt.
        private func recordRepairAndPresentationRows(on interrupted: MeasurementsStore) async {
            // ── Row 5 — the repair the operator does NOT know he has: leaving
            //    Insights and coming back mounts a new container, whose `.task`
            //    calls `loadAvailability()` again. If this row recovers where
            //    row 3 did not, then the surface is repairable and the repair
            //    is simply not reachable from the affordance that looks like it.
            let secondVisitStarted = Date()
            await interrupted.loadAvailability()
            record(String(
                format: "row5 second-visit (uninterrupted .task): kinds=%d elapsed=%.3fs",
                interrupted.availableKinds.count,
                Date().timeIntervalSince(secondVisitStarted)
            ))

            // ── Row 6 — the presentation question, decided rather than argued.
            //    The b266-vs-b267 reading says a stranded `isLoading` painted a
            //    skeleton over the same absent data. That gate is
            //    `InsightsStore.isInitialSkeletonVisible`, and it covers the
            //    OVERVIEW BODY — never the tab strip, which has no skeleton at
            //    any point in its composition. And for an operator who has mood
            //    entries, `anyDataPresent` is already true, so the silhouette
            //    was not on screen in b266 either.
            let skeletonForAnOperatorWithMood = InsightsStore.isInitialSkeletonVisible(
                hasSettledOnce: false,
                isLoading: true,
                hasComprehensive: false,
                hasCards: false,
                hasMeasurements: false,
                hasHealthScore: false,
                hasTargets: false,
                hasMood: true
            )
            record("row6 overview-skeleton-with-mood-entries: \(skeletonForAnOperatorWithMood)")
        }
    }

#endif
