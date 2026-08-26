import CryptoKit
import Foundation

// Phase 07 Wave 0 — executable contracts for HealthKit durability and complete
// sync.
//
// This file is deliberately behaviour-free. It names the vocabulary every later
// Phase-07 plan must speak (cursor identity, migration state, owner lease,
// stable retry identity, trigger budget, capability, disposition) and it pins
// the CURRENT, observed production semantics behind two named seams:
//
//   * `HealthSyncCursorPolicy.installed` — the cursor-commit rule the app runs
//     today (SpeziHealthKit 1.4.2 `a86db5c` saves the query anchor after the
//     app handler returns; `MoodStateOfMindImporter.runAnchoredSweep` saves the
//     anchor after a per-item failure; `HeartHealthEventImporter` holds only
//     when the upload throws).
//   * `HealthSyncCompositionPlan.installed(for:)` — the capability set each
//     trigger actually reaches today.
//
// Wave 0's RED suites compare those seams against `…required…`. They fail until
// the owning wave both repoints the seam AND wires the production path, because
// the same suites additionally assert that the named production files reference
// these contracts. No Wave-0 assertion may be renamed, skipped, or weakened.

// MARK: - Sources and capabilities

// `HealthSyncSource` lives in `HealthLog/Sync/HealthSyncRetryIdentity.swift`
// alongside `HealthSyncRetryEnvelope`: the retry identity is the one piece of
// this vocabulary a durable write needs outside the HealthKit layer, and the
// widget extension compiles the repositories that produce it.

/// A named unit of sync work. "Sync everything" is exactly this enumeration —
/// a path that is off, unsupported, or postponed must still return a named
/// disposition rather than disappearing.
enum HealthSyncCapability: String, CaseIterable, Sendable {
    case speziSampleCollection
    case workoutImport
    case ecgUpload
    case dailyStatistics
    case heartRateBuckets
    case nutrientDailyTotals
    case moodStateOfMindImport
    case appleMedicationImport
    case cycleImport
    case heartHealthEvents
    case outboxDrain

    var source: HealthSyncSource {
        switch self {
        case .speziSampleCollection: .speziSamples
        case .workoutImport: .workout
        case .ecgUpload: .ecg
        case .dailyStatistics: .dailyStatistics
        case .heartRateBuckets: .heartRateBucket
        case .nutrientDailyTotals: .nutrient
        case .moodStateOfMindImport: .mood
        case .appleMedicationImport: .appleMedication
        case .cycleImport: .cycle
        case .heartHealthEvents: .heartEvent
        case .outboxDrain: .outbox
        }
    }

    /// `true` for the one capability that collects the registry sample types.
    /// Every other capability is a non-sample importer and must appear by name
    /// in the complete-sync inventory.
    var isSampleCollection: Bool {
        self == .speziSampleCollection
    }

    /// Paths behind an explicit device-local opt-in. They are never silently
    /// omitted: an opt-out is reported as `.disabled`.
    var requiresExplicitOptIn: Bool {
        switch self {
        case .ecgUpload, .moodStateOfMindImport, .appleMedicationImport, .cycleImport, .nutrientDailyTotals:
            true
        default:
            false
        }
    }
}

/// The outcome vocabulary a capability may report. `ran` is the neutral
/// "entered" marker used by routing proofs; the remaining cases are terminal
/// for one pass.
enum HealthSyncDisposition: String, CaseIterable, Sendable {
    case ran
    case succeeded
    case retryPersisted
    case failed
    case disabled
    case unsupported
    case deferred
    case expired
}

// MARK: - Triggers, budgets, and honest scheduling

/// Every way collection can begin. `accountTeardown` is a trigger too: it must
/// reach exactly the captured owner's partitions and nothing else.
enum HealthSyncTrigger: String, CaseIterable, Sendable {
    case coldActivation
    case postAuthentication
    case foreground
    case manual
    case silentPush
    case appRefresh
    case processing
    case observer
    case accountTeardown
}

/// Bounded work allowance for one trigger. `incrementalOnly` forbids a first
/// history walk inside a short wake.
struct HealthSyncBudget: Sendable, Equatable {
    let maxPagesPerType: Int
    let incrementalOnly: Bool
    let allowsFirstHistoryImport: Bool

    static func required(for trigger: HealthSyncTrigger) -> HealthSyncBudget {
        switch trigger {
        case .appRefresh, .silentPush:
            HealthSyncBudget(maxPagesPerType: 1, incrementalOnly: true, allowsFirstHistoryImport: false)
        case .observer:
            HealthSyncBudget(maxPagesPerType: 1, incrementalOnly: false, allowsFirstHistoryImport: false)
        case .processing:
            HealthSyncBudget(maxPagesPerType: 8, incrementalOnly: false, allowsFirstHistoryImport: true)
        case .coldActivation, .postAuthentication, .foreground, .manual:
            HealthSyncBudget(maxPagesPerType: 4, incrementalOnly: false, allowsFirstHistoryImport: true)
        case .accountTeardown:
            HealthSyncBudget(maxPagesPerType: 0, incrementalOnly: true, allowsFirstHistoryImport: false)
        }
    }
}

/// iOS decides whether and when a submitted background request runs. The app
/// may never claim a period; this constant exists so a UI or review-copy test
/// can pin the honest wording.
enum HealthSyncSchedulingTruth {
    static let guaranteesFixedPeriod = false
    static let claim = "syncs when iOS grants background time and when HealthKit delivers updates"
}

// MARK: - Cursor identity and migration

/// `{owner, source, type}` cursor identity. Construction fails closed on a
/// blank owner so no cursor can ever be installation-global again.
struct HealthSyncCursorKey: Hashable, Sendable {
    let ownerID: String
    let source: HealthSyncSource
    let typeIdentifier: String

    init?(ownerID: String, source: HealthSyncSource, typeIdentifier: String) {
        let owner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = typeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !type.isEmpty else { return nil }
        self.ownerID = owner
        self.source = source
        self.typeIdentifier = type
    }

    /// Storage key. The `v2` segment keeps the new namespace disjoint from both
    /// the legacy `hl.healthkit.anchor.*` keys and Spezi's global slots, so a
    /// migration can quarantine instead of overwrite.
    var storageKey: String {
        "hl.sync.cursor.v2.\(source.rawValue).\(Self.token(for: ownerID)).\(typeIdentifier)"
    }

    private static func token(for ownerID: String) -> String {
        let digest = SHA256.hash(data: Data(ownerID.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// Versioned, fail-closed migration state per cursor key.
enum HealthSyncCursorMigrationState: Sendable, Equatable {
    case notStarted
    /// The legacy value is retained under `quarantineReference` and collection
    /// replays from the user's selected cutoff instead of adopting it.
    case replayingLegacy(quarantineReference: String)
    case verified
    case failed(reason: String)

    /// Only a verified or actively replaying partition may collect. `notStarted`
    /// and `failed` hold, so an unproven migration can never silently collect
    /// under the wrong owner.
    var permitsCollection: Bool {
        switch self {
        case .verified, .replayingLegacy: true
        case .notStarted, .failed: false
        }
    }

    /// A migration is complete only after a verified read-back.
    var isComplete: Bool {
        self == .verified
    }
}

// MARK: - Owner lease adapter

/// Phase-07 adapter over Phase-06's `AuthenticatedSessionLease`.
///
/// Phase 06 owns the single owner/generation authority. This type adds no
/// counter of its own: it forwards identity and currency, so an importer and a
/// teardown path can never disagree about which account is live.
struct HealthSyncOwnerLease: Sendable {
    let session: AuthenticatedSessionLease
    let source: HealthSyncSource

    var ownerID: String {
        session.ownerID
    }

    var generation: UInt64 {
        session.generation
    }

    var isCurrent: Bool {
        session.isCurrent
    }

    func requireCurrent() throws {
        try session.requireCurrent()
    }

    /// Captures the currently active owner from the Phase-06 registry.
    static func capture(
        from registry: AuthenticatedSessionLeaseRegistry,
        ownerID: String,
        source: HealthSyncSource
    ) -> HealthSyncOwnerLease? {
        guard let session = registry.capture(ownerID: ownerID) else { return nil }
        return HealthSyncOwnerLease(session: session, source: source)
    }

    /// The cursor key this lease may write. Cursor writes are owner-bound by
    /// construction rather than by convention.
    func cursorKey(typeIdentifier: String) -> HealthSyncCursorKey? {
        HealthSyncCursorKey(ownerID: ownerID, source: source, typeIdentifier: typeIdentifier)
    }
}

// MARK: - Deployed measurement response contract

/// The exact per-entry status vocabulary the deployed server emits.
enum DeployedMeasurementEntryStatus: String, CaseIterable, Sendable {
    case inserted
    case updated
    case duplicate
    case skipped
    case failed
}

/// Whether a response row lets the cursor move.
enum HealthSyncAcceptanceClass: String, Sendable, Equatable {
    case terminalAccepted
    case nonterminal
}

/// Source-pinned facts about the deployed measurement batch route.
enum DeployedMeasurementContract {
    static let serverTag = "v1.37.12"
    static let serverRevision = "d21fe48"
    /// A `stats:` external id is a mutable upsert. Within one batch the last
    /// matching row wins and the earlier one is reported duplicate with this
    /// reason.
    static let supersededInBatchReason = "superseded_in_batch"

    /// The classification Phase 07 must implement.
    static func required(for status: DeployedMeasurementEntryStatus) -> HealthSyncAcceptanceClass {
        switch status {
        case .inserted, .updated, .duplicate, .skipped: .terminalAccepted
        case .failed: .nonterminal
        }
    }

    /// The classification the shipped client reaches today, expressed through
    /// the real production decoder and the real acceptance switch.
    ///
    /// Returns `nil` when the shipped `HealthKitEntryStatus` cannot even name
    /// the deployed status word.
    ///
    /// The switch is exhaustive on purpose: extending the shipped vocabulary
    /// without deciding here what the new word means fails the build rather than
    /// falling into a default that would silently advance a cursor.
    static func installedClientClassification(forRawStatus raw: String) -> HealthSyncAcceptanceClass? {
        guard let decoded = HealthKitEntryStatus(rawValue: raw) else { return nil }
        switch decoded {
        case .inserted, .updated, .duplicate, .skipped: return .terminalAccepted
        case .failed, .unknown: return .nonterminal
        }
    }
}

// MARK: - Cursor commit decision

/// One response row reconciled back to the object that produced it.
struct HealthSyncEntryOutcome: Sendable, Equatable {
    let index: Int
    let stableIdentity: String
    /// `nil` means the row was missing, repeated, out of range, or carried a
    /// status this build cannot classify.
    let classification: HealthSyncAcceptanceClass?
}

/// Everything a commit decision may consult for one page.
struct HealthSyncPageOutcome: Sendable, Equatable {
    let postedCount: Int
    let entries: [HealthSyncEntryOutcome]
    /// The transport itself raised — today's importers hold the cursor only
    /// through this signal.
    let transportThrew: Bool
    /// A durable, owner-bound retry row was written for everything not
    /// terminally accepted.
    let durableRetryPersisted: Bool
    /// A durable retry write was attempted and failed.
    let durableRetryFailed: Bool
    let leaseIsCurrent: Bool
    let wasCancelled: Bool

    var hasNonterminalEntry: Bool {
        entries.contains { $0.classification != .terminalAccepted }
    }

    var coversEveryPostedIndex: Bool {
        let indexes = Set(entries.map(\.index))
        return indexes.count == entries.count && indexes == Set(0 ..< max(0, postedCount))
    }
}

enum HealthSyncHoldReason: String, Sendable, Equatable {
    case nonterminalEntry
    case incompleteIndexCoverage
    case retryPersistenceFailed
    case leaseLost
    case cancelled
}

enum HealthSyncCommitDecision: Sendable, Equatable {
    case commit
    case hold(reason: HealthSyncHoldReason)
}

/// The single decision point between a HealthKit page and its cursor.
protocol HealthSyncCursorCommitPolicy: Sendable {
    func decide(_ outcome: HealthSyncPageOutcome) -> HealthSyncCommitDecision
}

/// The rule Phase 07 must reach: commit only after exact terminal acceptance of
/// every posted index, or after a durable owner-bound retry row exists — and
/// never across cancellation or a lost lease.
struct DurableHealthSyncCursorCommitPolicy: HealthSyncCursorCommitPolicy {
    func decide(_ outcome: HealthSyncPageOutcome) -> HealthSyncCommitDecision {
        if outcome.wasCancelled { return .hold(reason: .cancelled) }
        if !outcome.leaseIsCurrent { return .hold(reason: .leaseLost) }
        if outcome.durableRetryFailed { return .hold(reason: .retryPersistenceFailed) }
        if !outcome.coversEveryPostedIndex { return .hold(reason: .incompleteIndexCoverage) }
        if outcome.hasNonterminalEntry, !outcome.durableRetryPersisted {
            return .hold(reason: .nonterminalEntry)
        }
        return .commit
    }
}

/// A faithful model of the rule the app runs today.
///
/// SpeziHealthKit 1.4.2 persists the query anchor once the app handler returns;
/// `MoodStateOfMindImporter` saves its anchor after a swallowed per-item
/// failure; `HeartHealthEventImporter` holds only because the uploader throws.
/// In all three, nothing except a raised transport error is consulted.
struct LegacyTransportOnlyCursorCommitPolicy: HealthSyncCursorCommitPolicy {
    func decide(_ outcome: HealthSyncPageOutcome) -> HealthSyncCommitDecision {
        outcome.transportThrew ? .hold(reason: .nonterminalEntry) : .commit
    }
}

/// The commit rule installed in production.
///
/// **Repointed by plan 07-03, in the commit that made it true.** Until that
/// commit the app ran ``LegacyTransportOnlyCursorCommitPolicy`` and this value
/// said so, because the only thing standing between a HealthKit page and its
/// cursor was SpeziHealthKit's unconditional post-callback anchor write. Three
/// production changes landed together and made the durable rule the one that
/// actually runs:
///
///   * the thirty-five server-bound `CollectSamples` registrations were removed
///     from `HealthLogSpeziDelegate`, so nothing advances an installation-global
///     anchor behind the app's back;
///   * `AnchoredHealthSampleCollector` issues the queries and commits through
///     `DurableHealthCursorStore.commit(page:anchor:for:requiring:)`, which
///     applies ``required`` verbatim;
///   * `HealthLogStandard` classifies its pages into `HealthSyncPageOutcome` and
///     consults this value, and `SpeziAnchorMigrator` establishes the
///     `HealthSyncCursorMigrationState` every partition must have before it may
///     collect at all.
///
/// The two constants are deliberately still two names: `installed` is what the
/// app runs and `required` is what Phase 07 demands. They are equal today, and
/// the Wave-0 matrix is what proves it.
enum HealthSyncCursorPolicy {
    static let installed: any HealthSyncCursorCommitPolicy = DurableHealthSyncCursorCommitPolicy()
    static let required: any HealthSyncCursorCommitPolicy = DurableHealthSyncCursorCommitPolicy()
}

// MARK: - Complete-sync composition

/// Capability sets per trigger: what each trigger must reach, and what it
/// actually reaches today.
enum HealthSyncCompositionPlan {
    /// Every enabled importer participates in a manual or foreground sweep.
    static let completeSet: Set<HealthSyncCapability> = Set(HealthSyncCapability.allCases)

    /// Incremental, short-wake subset: no first history import, no aggregate
    /// backfill.
    static let incrementalSet: Set<HealthSyncCapability> = [
        .speziSampleCollection,
        .workoutImport,
        .heartHealthEvents,
        .moodStateOfMindImport,
        .outboxDrain
    ]

    static func required(for trigger: HealthSyncTrigger) -> Set<HealthSyncCapability> {
        switch trigger {
        case .manual, .foreground, .processing, .postAuthentication:
            completeSet
        case .appRefresh, .silentPush:
            incrementalSet
        case .coldActivation:
            // Cold activation installs the chosen cutoff and starts observers;
            // it performs one initial sweep of everything enabled.
            completeSet
        case .observer:
            // Resolved against the signalled source, never a fan-out.
            []
        case .accountTeardown:
            []
        }
    }

    /// What the shipped composition reaches today, read off the production call
    /// sites named in `07-TRIGGER-OWNERSHIP.md`.
    ///
    /// **Five triggers repointed by plan 07-07, in the commit that made them
    /// true.** `HealthSyncOrchestrator` is installed behind
    /// ``AppOwnedHealthCollection``, which every pull trigger already funnels
    /// into through `SpeziCollectionTrigger`, and it runs the *plan* for the
    /// trigger rather than the sample types alone. So `foreground`, `manual`,
    /// `processing`, `silentPush` and `appRefresh` now reach every capability
    /// their plan names, each with a named disposition.
    ///
    /// **`coldActivation` and `postAuthentication` moved in plan 07-09**, in the
    /// commit that changed the three call sites they name.
    /// `RootView.activateHealthKitBackgroundIfReady`,
    /// `HKReadinessStore.requestAuthorization` and
    /// `HealthKitPermissionStep.activateHealthKitBackground` used to reach
    /// `activateHealthKitBackgroundDeliveries`, which armed HK delivery and then
    /// ran a `.foreground` collection trigger plus a detached aggregate sweep — a
    /// pass under the wrong name, and a second fan-out beside it. Each of the
    /// three now names its own trigger and enters
    /// `AppContainer.runHealthSyncPass` once.
    static func installed(for trigger: HealthSyncTrigger) -> Set<HealthSyncCapability> {
        switch trigger {
        case .foreground, .manual, .processing:
            // Through `AppContainer.runHealthSyncPass` → `SpeziCollectionTrigger`
            // → `AppOwnedHealthCollection` → `HealthSyncOrchestrator.run(trigger)`,
            // whose plan is `completeSet`.
            completeSet
        case .appRefresh, .silentPush:
            // Same route; the plan for a short wake is the incremental set, and
            // the remaining capabilities are named `deferred`, never omitted.
            completeSet
        case .coldActivation, .postAuthentication:
            // Same route again, entered detached so the connect surface never
            // waits on a first history import.
            completeSet
        case .observer, .accountTeardown:
            []
        }
    }

    /// Whether any production path activates the Phase-06 authenticated-session
    /// registry that every Phase-07 admission is resolved against.
    ///
    /// **`true` since plan 07-09, in the commit that made it true.** Through
    /// Waves 1-4 this was `false`, and it was the single most consequential fact
    /// in the phase: the activation seams existed and were called only from
    /// tests, so `AuthenticatedSessionLeaseRegistry.capture` returned `nil` on a
    /// real device, `HealthSyncAuthenticatedLease.admit` threw
    /// `unavailableAuthentication`, and every admission-gated sweep — the
    /// app-owned sample collection, the daily statistics, the State-of-Mind
    /// import, the Apple-medication import, the cycle import and the heart-event
    /// import — refused, while every toggle still read "on". The unit suite could
    /// not see it because every test activated the registry by hand.
    ///
    /// The fix is one statement rather than a list of call sites:
    /// `AuthStore.phase`'s `didSet` already maintained the identity epoch, so it
    /// now activates the shared registry for an owner that appears and
    /// invalidates it for an owner that goes away. Every real admission —
    /// `bootstrap()`, password/passkey/MFA/SSO/web-login, `register`,
    /// `completeOnboarding()`, a sharing-recovery actor change — passes through
    /// it, and so do the transitions that previously left a live registry behind
    /// an unauthenticated shell (`enterStandaloneMode()`, `beginServerPairing()`).
    ///
    /// `CompleteHealthSyncCompositionTests` compares this constant against the
    /// production sources with comment lines stripped, so it cannot drift from
    /// the call graph in either direction: removing the activation without
    /// flipping this back fails, and flipping it without an activation fails.
    static let installedActivatesSessionRegistry = true
    static let requiredActivatesSessionRegistry = true

    /// Cold activation must persist and install the selected backfill cutoff
    /// before the first query or observer registration.
    ///
    /// **True since plan 07-03.** The Spezi delegate used to resolve the cutoff
    /// while building its `configuration` — during launch, before onboarding had
    /// persisted the user's choice — and bake it into thirty-five `CollectSamples`
    /// declarations. Those declarations are gone.
    /// `AnchoredHealthSampleCollector` takes the cutoff as a parameter of every
    /// pass, and `AppOwnedHealthCollectionCoordinator` resolves it from
    /// `HealthKitBackfillWindowStore` at trigger time, after admission. A
    /// collector that cannot be handed a cutoff cannot query.
    static let installedInstallsCutoffBeforeFirstQuery = true
    static let requiredInstallsCutoffBeforeFirstQuery = true
}
