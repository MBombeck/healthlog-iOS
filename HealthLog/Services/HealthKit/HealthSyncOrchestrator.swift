import Foundation

// Phase 07 Wave 4 — one capability-complete, lease-aware entry point for every
// HealthKit lifecycle trigger.
//
// The problem this file exists for is omission, not failure. Before it, "sync
// everything" was whatever the call site that happened to fire remembered to
// call: the foreground refresh reached six capabilities, the manual button six
// (a different six), the BGProcessing wake five, and nothing at all reached the
// cycle or heart-event imports outside their own observers. A capability that
// is off, unsupported, refused, or cut short by an expiring background task is
// a legitimate outcome; a capability that nobody thought about is not, and the
// two were indistinguishable because neither produced a word.
//
// So the orchestrator's contract is narrow and total: for a trigger, resolve the
// planned capability set from `HealthSyncCompositionPlan`, and return exactly
// one named `HealthSyncCapabilityResult` per planned capability. Cancellation
// and expiration do not shorten the answer — they change the disposition of the
// capabilities that did not get to run, which is why `expired` is a case of
// `HealthSyncDisposition` rather than an early `return`.
//
// The actor itself owns coalescing and the pass record only. Construction lives
// in `+Registry` and the per-trigger plans live in `+Execution`.

/// Why a capability did not finish, in terms that can be logged and shown.
///
/// Deliberately non-sensitive by construction: there is no associated value, so
/// no owner id, bearer, URL, external id, dose name, Mood label, ECG waveform,
/// or health value can ride along. A diagnostic surface renders the case name.
enum HealthSyncFailureClass: String, Sendable, Equatable, CaseIterable {
    /// Admission itself was refused — no owner/bearer pair to work under. This
    /// is the case an inert authenticated-session registry produces, and it is
    /// separate from `staleSession` precisely so "we were never admitted" can
    /// never be read as "the account changed under us".
    case notAdmitted
    /// The owner, session generation, or pinned bearer moved on mid-pass.
    case staleSession
    /// Cooperative cancellation (teardown, app suspension).
    case cancelled
    /// The trigger's window closed before this capability ran or finished.
    case expired
    /// HealthKit authorization is missing or was revoked for the type set.
    case authorization
    /// The request never reached a server answer.
    case transport
    /// The server answered and did not accept.
    case serverRejected
    /// A durable local write (cursor, ledger, outbox row) did not persist.
    case persistence
    /// The capability's types do not exist on this OS/device.
    case unsupportedOnDevice
    case unknown
}

/// One capability's named answer for one pass.
///
/// Counts are cardinalities, never contents. `itemsHeld` is the operator-facing
/// number that matters: it is what the account is still owed.
struct HealthSyncCapabilityResult: Sendable, Equatable {
    let capability: HealthSyncCapability
    let disposition: HealthSyncDisposition
    let itemsSubmitted: Int
    let itemsSettled: Int
    let itemsHeld: Int
    let durationMilliseconds: Int
    let failure: HealthSyncFailureClass?
    let holdReason: HealthSyncHoldReason?

    init(
        capability: HealthSyncCapability,
        disposition: HealthSyncDisposition,
        itemsSubmitted: Int = 0,
        itemsSettled: Int = 0,
        itemsHeld: Int = 0,
        durationMilliseconds: Int = 0,
        failure: HealthSyncFailureClass? = nil,
        holdReason: HealthSyncHoldReason? = nil
    ) {
        self.capability = capability
        self.disposition = disposition
        self.itemsSubmitted = max(0, itemsSubmitted)
        self.itemsSettled = max(0, itemsSettled)
        self.itemsHeld = max(0, itemsHeld)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.failure = failure
        self.holdReason = holdReason
    }

    /// The capability is behind an opt-in the user has not granted, or its
    /// feature module is off. Named, never omitted.
    static func disabled(_ capability: HealthSyncCapability) -> Self {
        Self(capability: capability, disposition: .disabled)
    }

    /// The capability cannot exist on this OS/device build.
    static func unsupported(_ capability: HealthSyncCapability) -> Self {
        Self(capability: capability, disposition: .unsupported, failure: .unsupportedOnDevice)
    }

    /// The pass never got to this capability because the window closed.
    static func expired(_ capability: HealthSyncCapability) -> Self {
        Self(capability: capability, disposition: .expired, failure: .expired)
    }

    /// The pass never got to this capability because the work was cancelled.
    static func cancelled(_ capability: HealthSyncCapability) -> Self {
        Self(capability: capability, disposition: .expired, failure: .cancelled)
    }

    /// The capability ran and finished everything it planned.
    static func succeeded(
        _ capability: HealthSyncCapability,
        submitted: Int = 0,
        settled: Int = 0,
        milliseconds: Int = 0
    ) -> Self {
        Self(
            capability: capability,
            disposition: .succeeded,
            itemsSubmitted: submitted,
            itemsSettled: settled,
            durationMilliseconds: milliseconds
        )
    }

    /// The capability entered and did work whose completeness this pass cannot
    /// prove. The neutral marker — never a claim that anything landed.
    static func ran(_ capability: HealthSyncCapability, milliseconds: Int = 0) -> Self {
        Self(capability: capability, disposition: .ran, durationMilliseconds: milliseconds)
    }

    /// The capability was refused before it could touch HealthKit.
    static func refused(_ capability: HealthSyncCapability, _ failure: HealthSyncFailureClass) -> Self {
        Self(
            capability: capability,
            disposition: .failed,
            failure: failure,
            holdReason: failure == .notAdmitted || failure == .staleSession ? .leaseLost : nil
        )
    }

    /// `true` when this result leaves the account owed something.
    var owesWork: Bool {
        switch disposition {
        case .succeeded, .disabled, .unsupported: false
        case .ran, .retryPersisted, .failed, .deferred, .expired: true
        }
    }
}

/// The aggregate a trigger produces: exactly one result per planned capability.
struct HealthSyncPassResult: Sendable, Equatable {
    let trigger: HealthSyncTrigger
    let planned: Set<HealthSyncCapability>
    let results: [HealthSyncCapabilityResult]
    let startedAt: Date
    let durationMilliseconds: Int
    let wasCancelled: Bool
    let wasExpired: Bool

    /// Planned capabilities with no named answer. A non-empty set is a bug in
    /// this file, not a legitimate state, and the aggregate says so rather than
    /// letting the pass read as complete.
    var omitted: Set<HealthSyncCapability> {
        planned.subtracting(results.map(\.capability))
    }

    /// Capabilities that refused because nothing admitted an account.
    ///
    /// Its own accessor because it is the one refusal that is a *composition*
    /// defect rather than a runtime condition: it means the app never told the
    /// authenticated-session registry who is signed in, so every admission-gated
    /// sweep declines while every toggle still reads "on".
    var refusedForMissingAdmission: [HealthSyncCapability] {
        results.filter { $0.failure == .notAdmitted }.map(\.capability)
    }

    var heldItemCount: Int {
        results.reduce(0) { $0 + $1.itemsHeld }
    }

    /// `false` while anything is omitted, cut short, held, or merely `ran`.
    ///
    /// A durable retry row is progress but it is not completion: the work is
    /// owed, and a surface that called it done would be making the exact claim
    /// this phase exists to remove.
    var isComplete: Bool {
        guard omitted.isEmpty, !wasCancelled, !wasExpired else { return false }
        return results.allSatisfy { !$0.owesWork }
    }

    func result(for capability: HealthSyncCapability) -> HealthSyncCapabilityResult? {
        results.first { $0.capability == capability }
    }

    /// The publishable projection of this pass.
    ///
    /// Everything in it is a fixed enum case name, a cardinality, or a
    /// timestamp. There is no arm on this type through which an owner id, a
    /// bearer, a server URL, an external id, a dose name, a Mood label, an ECG
    /// waveform, or a health value could reach a surface — not because the
    /// caller is careful, but because the snapshot has nowhere to put one.
    var publicSnapshot: HealthSyncPassSnapshot {
        HealthSyncPassSnapshot(
            trigger: trigger.rawValue,
            startedAt: startedAt,
            durationMilliseconds: durationMilliseconds,
            isComplete: isComplete,
            heldItemCount: heldItemCount,
            omittedCapabilities: omitted.map(\.rawValue).sorted(),
            capabilities: results.map {
                HealthSyncPassSnapshot.Capability(
                    capability: $0.capability.rawValue,
                    disposition: $0.disposition.rawValue,
                    itemsSubmitted: $0.itemsSubmitted,
                    itemsSettled: $0.itemsSettled,
                    itemsHeld: $0.itemsHeld,
                    failure: $0.failure?.rawValue,
                    holdReason: $0.holdReason?.rawValue
                )
            }
        )
    }

    /// An empty pass for a trigger whose plan is resolved elsewhere
    /// (`accountTeardown`) or that had nothing planned.
    static func empty(_ trigger: HealthSyncTrigger, startedAt: Date = Date()) -> Self {
        Self(
            trigger: trigger,
            planned: [],
            results: [],
            startedAt: startedAt,
            durationMilliseconds: 0,
            wasCancelled: false,
            wasExpired: false
        )
    }
}

/// What a pass may be told about, outside the HealthKit layer.
///
/// `public` because the canonical sync-status store and the diagnostics surface
/// are public and the internal capability vocabulary is not. Every field is a
/// fixed enum case name, a count, or a timestamp — the type is privacy-safe by
/// shape rather than by discipline.
public struct HealthSyncPassSnapshot: Sendable, Equatable, Codable {
    public struct Capability: Sendable, Equatable, Codable {
        public let capability: String
        public let disposition: String
        public let itemsSubmitted: Int
        public let itemsSettled: Int
        public let itemsHeld: Int
        /// Non-sensitive failure class, e.g. `notAdmitted`, `transport`.
        public let failure: String?
        /// The cursor hold reason, when one applies.
        public let holdReason: String?
    }

    public let trigger: String
    public let startedAt: Date
    public let durationMilliseconds: Int
    /// `false` while anything was omitted, cut short, held, or merely entered.
    public let isComplete: Bool
    public let heldItemCount: Int
    /// Planned capabilities that produced no answer. Non-empty is a defect.
    public let omittedCapabilities: [String]
    public let capabilities: [Capability]

    /// Capabilities refused because no account could be admitted.
    public var capabilitiesRefusedForMissingAdmission: [String] {
        capabilities.filter { $0.failure == HealthSyncFailureClass.notAdmitted.rawValue }.map(\.capability)
    }

    /// Capabilities the pass named as still owing work.
    public var capabilitiesOwingWork: [String] {
        capabilities
            .filter { $0.disposition != "succeeded" && $0.disposition != "disabled" && $0.disposition != "unsupported" }
            .map(\.capability)
    }
}

/// Everything one capability adapter may consult for one pass.
struct HealthSyncRunContext: Sendable {
    let trigger: HealthSyncTrigger
    let budget: HealthSyncBudget
    /// For `.observer` passes: the one source that was signalled. `nil` for
    /// every fan-out trigger. An observer pass is never a fan-out.
    let observedSource: HealthSyncSource?
    /// The trigger's window. Consulted before each capability and available to
    /// an adapter that can bound its own work.
    let isExpired: @Sendable () -> Bool

    var isCancelledOrExpired: Bool {
        Task.isCancelled || isExpired()
    }
}

/// One capability-complete pass per trigger.
///
/// The core is deliberately three stored properties and one entry point: the
/// registry it was constructed with, the coalescer that keeps two triggers from
/// running the same plan twice, and the sink that publishes the named result.
/// Plans live in `+Execution`; construction lives in `+Registry`.
actor HealthSyncOrchestrator {
    let registry: HealthSyncCapabilityRegistry

    /// Publishes a finished pass. The composition root points this at the
    /// canonical sync-status store and the diagnostics counters; a context that
    /// installs nothing simply loses the report, which is why the result is also
    /// returned to the caller.
    private let report: @Sendable (HealthSyncPassResult) async -> Void

    private let coalescer = SweepCoalescer()

    /// Results of coalesced passes, taken back by the caller that filled them.
    /// A trigger whose token is never filled was folded into an in-flight pass
    /// and reports `.deferred` — which is exactly what happened to it.
    private var passTokens: [UUID: HealthSyncPassResult] = [:]

    /// The last finished pass per trigger, so a diagnostics surface can ask
    /// without subscribing.
    private(set) var lastPass: [HealthSyncTrigger: HealthSyncPassResult] = [:]

    init(
        registry: HealthSyncCapabilityRegistry,
        report: @escaping @Sendable (HealthSyncPassResult) async -> Void = { _ in }
    ) {
        self.registry = registry
        self.report = report
    }

    /// One bounded, coalesced pass for `trigger`.
    ///
    /// Coalescing is per trigger rather than global: a foreground refresh and a
    /// silent-push wake plan different capability sets, and folding one into the
    /// other would silently omit whatever the survivor did not plan.
    func run(
        _ trigger: HealthSyncTrigger,
        observedSource: HealthSyncSource? = nil,
        isExpired: @escaping @Sendable () -> Bool = { false }
    ) async -> HealthSyncPassResult {
        let token = UUID()
        let key = coalescingKey(trigger, observedSource)
        await coalescer.run(key: key) { [weak self] in
            guard let self else { return }
            let outcome = await executePass(trigger, observedSource: observedSource, isExpired: isExpired)
            await fill(token, with: outcome)
        }
        if let filled = takeToken(token) {
            lastPass[trigger] = filled
            await report(filled)
            return filled
        }
        return deferredPass(trigger)
    }

    private nonisolated func coalescingKey(_ trigger: HealthSyncTrigger, _ source: HealthSyncSource?) -> String {
        guard let source else { return trigger.rawValue }
        return "\(trigger.rawValue)#\(source.rawValue)"
    }

    private func fill(_ token: UUID, with result: HealthSyncPassResult) {
        passTokens[token] = result
    }

    private func takeToken(_ token: UUID) -> HealthSyncPassResult? {
        passTokens.removeValue(forKey: token)
    }

    /// The answer for a trigger that was folded into an in-flight pass. Every
    /// planned capability is named `.deferred` rather than dropped: the caller
    /// asked for a complete answer and "another pass is doing this" is one.
    private func deferredPass(_ trigger: HealthSyncTrigger) -> HealthSyncPassResult {
        let planned = registry.plannedCapabilities(for: trigger, observedSource: nil)
        return HealthSyncPassResult(
            trigger: trigger,
            planned: planned,
            results: registry.orderedPlan(planned).map {
                HealthSyncCapabilityResult(capability: $0, disposition: .deferred)
            },
            startedAt: Date(),
            durationMilliseconds: 0,
            wasCancelled: false,
            wasExpired: false
        )
    }
}
