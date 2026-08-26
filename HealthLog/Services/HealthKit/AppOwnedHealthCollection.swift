#if canImport(HealthKit) && canImport(SpeziHealthKit)
    import Foundation
    import HealthKit

    // Phase 07 Wave 2 — the cutover seam.
    //
    // The Spezi `CollectSamples` registrations that used to own server-bound sample
    // collection were removed in the same commit that added this file. That removal
    // is what "stops the old collectors": there is no longer any declaration for
    // SpeziHealthKit to arm, so nothing can race the app-owned path or advance an
    // installation-global anchor behind it.
    //
    // What starts instead is deliberately narrow. Every existing pull trigger —
    // the BGProcessing wake, the foreground revalidate, the manual "Jetzt syncen",
    // the silent push, and the post-authorization activation — already funnels
    // through `SpeziCollectionTrigger.trigger(source:)`. Routing the app-owned
    // collector through that one seam means the cutover introduces no new direct
    // trigger and touches no call site the orchestration plan owns.
    //
    // Two things must be true before the first query of a session, and both are
    // enforced here rather than hoped for:
    //
    //   * The authenticated account's migration state exists. Every server-bound
    //     partition quarantines the installation-global Spezi anchor and reports
    //     `replayingLegacy`; a partition without that state refuses to collect.
    //   * The 7/30/90/365-day cutoff that account chose during onboarding is
    //     resolved and passed in. The collector takes it as a parameter precisely
    //     so it cannot query before the choice is known.

    /// Process-wide handle on the app-owned sample collection.
    ///
    /// A single installed closure rather than a resolvable module: the composition
    /// root builds the collector once and installs it, and every trigger reaches it
    /// through the same call. Before installation — and while signed out — a
    /// trigger is a no-op, which is the correct fail-closed posture: there is no
    /// account to collect for.
    /// **Phase 07 Wave 4.** The seam now has two slots, and the reason is the
    /// difference between "collect the thirty-five sample types" and "run this
    /// trigger's plan".
    ///
    /// Wave 2 installed the sample-collection coordinator here and every pull
    /// trigger reached it. That was correct for the cutover and wrong as a
    /// definition of a pass: a manual sync that reaches only the sample types has
    /// silently omitted the cycle, heart-event, Mood, medication and ECG work,
    /// which is exactly the omission Wave 4 exists to close. So the sample
    /// coordinator keeps its own slot, and `install` now takes the orchestrated
    /// pass — which calls the sample slot as one capability among eleven.
    ///
    /// The fallback is deliberate and fail-safe in the right direction: a build
    /// or a test context that composes no orchestrator still collects samples
    /// exactly as it did before, rather than collecting nothing.
    @MainActor
    enum AppOwnedHealthCollection {
        /// One orchestrated pass. **Plan 07-09** widened the closure twice, and
        /// both arguments exist because a caller knows something the seam cannot
        /// infer: an observer wake knows *which* source signalled (so the pass
        /// resolves to that one capability instead of fanning out), and a
        /// background wake owns the `BGTask.expirationHandler` (so an
        /// about-to-be-terminated grant stops admitting and names the remainder
        /// `expired` rather than being killed mid-sweep).
        private static var installed: (
            @Sendable (HealthSyncTrigger, HealthSyncSource?, @escaping @Sendable () -> Bool) async
                -> [HealthSyncCapability]
        )?
        private static var installedSampleCollection:
            (@Sendable (HealthSyncTrigger) async -> HealthSyncCapabilityResult)?

        static var isInstalled: Bool {
            installed != nil || installedSampleCollection != nil
        }

        /// `true` once a trigger reaches the full capability plan rather than the
        /// sample types alone.
        static var isOrchestrated: Bool {
            installed != nil
        }

        /// Installs the one bounded pass a trigger runs (Plan 07-07).
        static func install(
            _ run: @escaping @Sendable (
                HealthSyncTrigger,
                HealthSyncSource?,
                @escaping @Sendable () -> Bool
            ) async -> [HealthSyncCapability]
        ) {
            installed = run
        }

        /// Installs the app-owned sample collection (Plan 07-03). Reached as the
        /// orchestrator's `speziSampleCollection` capability.
        static func installSampleCollection(
            _ run: @escaping @Sendable (HealthSyncTrigger) async -> HealthSyncCapabilityResult
        ) {
            installedSampleCollection = run
        }

        /// Runs the pass and answers with the capabilities it named.
        ///
        /// The return value is what lets a caller — the background coordinator in
        /// particular — report what a wake actually reached instead of logging
        /// that something happened.
        @discardableResult
        static func run(
            _ trigger: HealthSyncTrigger,
            observedSource: HealthSyncSource? = nil,
            isExpired: @escaping @Sendable () -> Bool = { false }
        ) async -> [HealthSyncCapability] {
            if let installed {
                return await installed(trigger, observedSource, isExpired)
            }
            let fallback = await runSampleCollection(trigger)
            return [fallback.capability]
        }

        /// A context with no installed collection says `unsupported` rather than
        /// returning quietly: "nothing collects samples here" is a fact the pass
        /// aggregate has to be able to state.
        static func runSampleCollection(_ trigger: HealthSyncTrigger) async -> HealthSyncCapabilityResult {
            guard let installedSampleCollection else {
                return .unsupported(.speziSampleCollection)
            }
            return await installedSampleCollection(trigger)
        }
    }

    /// Owns activation for one process: the account migration, the observer arming,
    /// and one bounded pass per trigger.
    actor AppOwnedHealthCollectionCoordinator {
        /// The registry identifiers that arm a change subscription. Exactly the set
        /// the removed `CollectSamples` declarations armed background delivery for
        /// (vital signs plus the R3 aggressive-cadence promotions); everything else
        /// is pull-only, which is the W2 battery posture unchanged.
        static var observedTypeIdentifiers: [String] {
            HealthLogSampleTypeRegistry.knownIdentifiers
                .filter { HealthKitBackgroundDeliveryPolicy.continuesInBackground(for: $0) }
                .sorted()
        }

        static var collectedTypeIdentifiers: [String] {
            HealthLogSampleTypeRegistry.knownIdentifiers.sorted()
        }

        private let collector: AnchoredHealthSampleCollector
        private let cursors: DurableHealthCursorStore
        private let admission: @Sendable () throws -> HealthSyncAuthenticatedLease
        private let cutoff: @Sendable () -> Date

        /// Owners whose partitions have already been established in this process.
        /// The store refuses a repeated migration anyway; this only avoids walking
        /// thirty-five partitions on every trigger.
        private var migratedOwners: Set<String> = []
        private var observing = false

        init(
            collector: AnchoredHealthSampleCollector,
            cursors: DurableHealthCursorStore,
            admission: @escaping @Sendable () throws -> HealthSyncAuthenticatedLease,
            cutoff: @escaping @Sendable () -> Date
        ) {
            self.collector = collector
            self.cursors = cursors
            self.admission = admission
            self.cutoff = cutoff
        }

        /// One bounded pass for `trigger`, with a name for what it did.
        ///
        /// Signed out — or, as of Wave 3, whenever nothing has activated the
        /// authenticated-session registry — this returns without touching
        /// HealthKit: there is no owner to attribute a page to and no bearer to
        /// send it under. It used to return silently, which is precisely why a
        /// composition in which admission always fails could look healthy. The
        /// refusal is now a named `notAdmitted` result that the orchestrator
        /// aggregates and the diagnostics surface counts.
        @discardableResult
        func run(_ trigger: HealthSyncTrigger) async -> HealthSyncCapabilityResult {
            let lease: HealthSyncAuthenticatedLease
            do {
                lease = try admission()
            } catch let refusal as HealthSyncLeaseRefusal {
                return .refused(.speziSampleCollection, Self.failureClass(for: refusal))
            } catch {
                return .refused(.speziSampleCollection, .unknown)
            }
            let window = cutoff()

            if !migratedOwners.contains(lease.ownerID) {
                await SpeziAnchorMigrator.migrateAccountCursors(
                    types: Self.collectedTypeIdentifiers,
                    store: cursors,
                    requiring: lease
                )
                migratedOwners.insert(lease.ownerID)
            }

            if !observing {
                observing = true
                await collector.startObserving(
                    Self.observedTypeIdentifiers,
                    notBefore: window,
                    admitting: admission
                )
            }

            await collector.collect(
                typeIdentifiers: Self.collectedTypeIdentifiers,
                trigger: trigger,
                notBefore: window,
                requiring: lease
            )
            // `ran`, not `succeeded`: the collector commits per type through the
            // shared cursor rule, and a page it held is still owed. Claiming
            // success here would be the overstatement this phase removes.
            return .ran(.speziSampleCollection)
        }

        /// Maps the lease vocabulary onto the pass vocabulary. Exhaustive, so a
        /// new refusal reason cannot fall into a generic bucket.
        private static func failureClass(for refusal: HealthSyncLeaseRefusal) -> HealthSyncFailureClass {
            switch refusal {
            case .unavailableAuthentication: .notAdmitted
            case .staleSession: .staleSession
            case .cancelled: .cancelled
            }
        }

        /// Fail-closed rollback: stop the new collectors and stop every partition
        /// of the signed-in account, without deleting a cursor, clearing a
        /// quarantine, or re-enabling anything.
        func stopFailClosed(reason: String) async {
            await collector.stopObserving()
            observing = false
            guard let lease = try? admission() else { return }
            await SpeziAnchorMigrator.failClosed(
                reason: reason,
                types: Self.collectedTypeIdentifiers,
                store: cursors,
                requiring: lease
            )
        }
    }
#endif
