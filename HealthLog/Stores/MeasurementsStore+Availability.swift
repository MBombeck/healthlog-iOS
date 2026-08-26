import Foundation

// MARK: - Availability (has-data per kind) + CoreSpotlight settle hook

public extension MeasurementsStore {
    /// v0.13.1 IC — refresh the per-kind has-data availability set from the
    /// all-time summaries slice. SWR-cached behind `.measurementAvailability`
    /// (5min TTL), so a warm tab-switch / foreground bounce paints from cache
    /// without a round-trip. Best-effort: a failure leaves the previously-loaded
    /// `availableKinds` intact (the strip keeps showing what it knew), never
    /// surfaces a user-facing error — availability is a progressive-reveal
    /// signal, not a blocking load. Standalone returns an empty set (the repo
    /// no-ops offline); the caller unions it with the on-device `recent`.
    ///
    /// **22-01 (R4)** — "best-effort" still meant "silent" until this plan.
    /// Every one of the three exits below now records exactly one countable
    /// `store-effect-refused store=measurements` line, so the sentence "no
    /// refusal line, therefore availability is fine" became TRUE in this build.
    /// 20-01 measured what its absence cost: a read cancelled at an 800 ms
    /// dwell leaves the strip permanently short and says nothing anywhere, and
    /// four investigations read that silence as evidence.
    ///
    /// The word matters as much as the line. `isCurrent` folds cancellation and
    /// supersession together; `ownsRegistryGeneration` (14-06) tells them
    /// apart, and they send an operator to different places — a superseded
    /// generation means another account is here now, a cancelled read means
    /// there was simply no result yet. Publication is untouched: recording a
    /// refusal never publishes, so the fences keep fencing.
    ///
    /// **W-B187 QOL-2** — on a successful (re)load it fires
    /// `onAvailabilityDidChange` so `AppContainer` can re-index the measured
    /// kinds into CoreSpotlight (a neutral category title + Insights deep-link
    /// per kind — never a value).
    /// - Returns: `true` when this call PUBLISHED availability (including the
    ///   legitimate empty answer a standalone install or a measurement-less
    ///   account gets), `false` on every one of the three refusal exits. The
    ///   distinction matters to the caller and nowhere else: an account that
    ///   genuinely has nothing and a read that was refused look identical in
    ///   `availableKinds`, and telling the operator "sections could not be
    ///   loaded" when nothing failed is its own small lie. Every `false` also
    ///   records exactly one countable refusal line.
    @discardableResult
    func loadAvailability() async -> Bool {
        // Exit 1 of 3 — no admitted owner: the read never started.
        guard let lease = captureAuthenticatedSessionLease() else {
            StoreEffectDiagnostics.recordRefusal(.leaseUnavailable, store: .measurements)
            return false
        }
        do {
            let kinds = try await repo.availableKinds()
            // Exit 2 of 3 — the LOST RACE, on the success path. The wire
            // answered, and the answer is no longer this session's to publish.
            guard authenticatedEffectIsCurrent(lease) else {
                StoreEffectDiagnostics.recordRefusal(Self.retiredRefusal(for: lease), store: .measurements)
                return false
            }
            // Monotonic within a session: union rather than replace so a
            // transient empty/failed revalidation can never DROP a kind the
            // strip already lit (mirrors the container's `seenKinds` latch).
            availableKinds.formUnion(kinds)
            onAvailabilityDidChange?(availableKinds)
            return true
        } catch {
            // Exit 3 of 3 — the catch, including its own stale-lease leg.
            guard authenticatedEffectIsCurrent(lease) else {
                StoreEffectDiagnostics.recordRefusal(Self.retiredRefusal(for: lease), store: .measurements)
                return false
            }
            StoreEffectDiagnostics.recordRefusal(Self.refusal(for: error), store: .measurements)
            HLLog.api.info(
                "MeasurementsStore.loadAvailability best-effort drop: \(LogSanitizer.redact(String(describing: error)))"
            )
            return false
        }
    }

    /// Which word a failed `isCurrent` deserves. A generation that moved on is
    /// a retired lease; a generation that is intact means only this task was
    /// cancelled, and blaming an account switch that never happened would send
    /// the next investigation to the wrong place.
    private static func retiredRefusal(
        for lease: AuthenticatedSessionLease
    ) -> StoreEffectDiagnostics.Refusal {
        lease.ownsRegistryGeneration ? .loadInterrupted : .leaseRetired
    }

    /// Cancellation is exactly the class `EndpointFailureDiagnostics.classify`
    /// refuses to give an endpoint line to — reuse that closed judgement rather
    /// than growing a second cancellation vocabulary beside it.
    private static func refusal(for error: any Error) -> StoreEffectDiagnostics.Refusal {
        EndpointFailureDiagnostics.classify(error) == nil ? .loadInterrupted : .loadFailed
    }
}
