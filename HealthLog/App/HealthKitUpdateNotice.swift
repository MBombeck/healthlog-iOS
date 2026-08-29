import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// **25-01 (decision E-2026-08-28).** The rule behind the one-time dashboard
/// card that tells an *existing* installation what an update changed about
/// Apple Health — because today nothing does.
///
/// **The dead end this type exists to name** (mechanism established by 12-12,
/// observed in the field on 2026-08-28): once any HealthKit authorization
/// request has ever run on a device, `hl.healthkit.requestedAt.<token>` is
/// written and `HKReadinessStore.isConnected` answers `true` for every
/// non-`.denied` state. `shouldShowDashboardBanner` refuses on that FIRST —
/// permanently, one-way. A user who dismissed or denied the onboarding sheet
/// therefore never sees a connect affordance again outside Einstellungen →
/// Apple Health. That latch is deliberate for the banner (the K10 sync-truth
/// override protects read-only users whose data demonstrably flows) and it is
/// pinned by 12-12's suite; this type does not touch it. The card carries its
/// OWN display rule, which reads arming + dismissal + `ConnectionState` and
/// nothing of `isConnected` / `lastSyncedAt` / `bannerDismissedAt`.
///
/// **Why arming comes from the launch prologue and not from onboarding
/// state:** the card must be impossible on a fresh install even when
/// onboarding is skipped. `FreshInstallGuard` already decides "fresh install
/// or not" once per install, from evidence that dies with the app
/// (the `hl.install.sentinel` and the 13-05 prior-launch witnesses), and
/// `LaunchPrologue` returns that decision as a ledger. `.freshInstall`
/// disarms the card permanently before any onboarding runs; the two
/// pre-existing outcomes arm it. A `.returningInstall` with no recorded
/// decision can only be an install whose sentinel was written by an OLDER
/// build — this build's own first launch records its decision in the same
/// `HealthLogApp.init` — which is precisely "this install was updated".
///
/// Both keys are per **install**, not per user, and deliberately live in
/// `UserDefaults.standard`: a delete-and-reinstall wipes them, and a
/// reinstalled app runs onboarding again, so the card stays silent there.
enum HealthKitUpdateNotice {
    /// The once-per-install arming decision. Value space is ``Arming``'s
    /// raw values; absence means "no decision", and no decision means no card.
    static let armingDefaultsKey = "hl.updateNotice.healthkit.arming"
    /// The ✕. `true` once the user dismissed the card; it never returns.
    static let dismissedDefaultsKey = "hl.updateNotice.healthkit.dismissed"

    /// What the launch decided, recorded exactly once per install.
    enum Arming: String, Equatable, Sendable {
        /// A pre-existing installation met this build for the first time —
        /// the card may show while the readiness state warrants it.
        case armed
        /// This install's first launch was a fresh install — the card may
        /// never show on this install, whatever the readiness state becomes.
        case disarmed
    }

    /// Which of the two decided states the card renders.
    enum Variant: Equatable, Sendable {
        /// Not connected at all — no write type authorized. The field case:
        /// `requestedAt` set, nothing granted, banner latched down.
        case connect
        /// Partially connected — something authorized, something missing
        /// (D-16-03-A's state, e.g. the State-of-Mind write from E2).
        case newTypes
    }

    /// **25-02 (E-2026-08-29 #5) — what the system answered about the
    /// authorization sheet** for the set the candidate variant would request:
    /// `HKHealthStore.getRequestStatusForAuthorization(toShare:read:)`, the
    /// ONE API that speaks for read types too. It never reveals what was
    /// granted (iOS tells nobody that for reads, by design —
    /// `authorizationStatus` is write-only); it answers whether the sheet is
    /// still to be *answered* for the whole set, which is exactly the
    /// boundary of what iOS will ever reveal. Grant and deny both flip it to
    /// ``answered`` — that is Apple's semantics, and the card's rule builds
    /// on nothing finer.
    enum SheetStatus: Equatable, Sendable {
        /// `.unnecessary` — the sheet has been answered for the whole set,
        /// grant or deny alike. Detection, not memory: the card's job is done.
        case answered
        /// `.shouldRequest` — something in the set is still unanswered.
        case open
        /// The platform cannot answer (non-HK build, seam without HealthKit).
        /// Falls back to the state rule — the shipped 25-01 behaviour.
        case unknown
    }

    #if canImport(HealthKit)
        /// The E2 delta the new-types variant announces — State of Mind
        /// (share + read) and ECG (read-only, ungrantable to observe). Always
        /// SUBSETS of the shipped default sets: the sheet-status query filters
        /// the default sets by these identifiers, so no type-set pin (the
        /// medication SIGABRT fence, the 5.1.3(i) transparency derivation)
        /// can move with this feature.
        static var newTypeShareIdentifiers: Set<String> {
            [HKObjectType.stateOfMindType().identifier]
        }

        static var newTypeReadIdentifiers: Set<String> {
            [HKObjectType.stateOfMindType().identifier, HKObjectType.electrocardiogramType().identifier]
        }
    #else
        static var newTypeShareIdentifiers: Set<String> {
            []
        }

        static var newTypeReadIdentifiers: Set<String> {
            []
        }
    #endif

    // MARK: - The launch decision

    /// Records the once-per-install arming decision from the launch
    /// prologue's ledger. Called by `HealthLogApp.init` directly after
    /// `LaunchPrologue.run`, on every launch.
    ///
    /// **First decision wins.** `.freshInstall` can only be this install's
    /// first launch, so recording `disarmed` there — before any onboarding
    /// runs, skipped or not — makes the card impossible on that install for
    /// good. Every LATER launch of the same install is `.returningInstall`
    /// and finds the decision already recorded. Conversely, a
    /// `.returningInstall` (or a pre-b267 `.preexistingInstall`) that finds
    /// NO decision means the sentinel was written by an older build: the
    /// install predates this build — an update — and the card is armed.
    ///
    /// A `nil` outcome (a prologue composed without the guard) records
    /// nothing: no decision, no card — the fail-closed direction.
    static func recordLaunch(
        outcome: FreshInstallGuard.Outcome?,
        defaults: UserDefaults = .standard
    ) {
        guard arming(in: defaults) == nil else { return }
        switch outcome {
        case .freshInstall:
            defaults.set(Arming.disarmed.rawValue, forKey: armingDefaultsKey)
        case .preexistingInstall, .returningInstall:
            defaults.set(Arming.armed.rawValue, forKey: armingDefaultsKey)
        case nil:
            break
        }
    }

    /// The recorded decision, or `nil` when no launch has decided yet.
    /// `nil` is fail-closed: ``visibleVariant`` shows nothing for it.
    static func arming(in defaults: UserDefaults = .standard) -> Arming? {
        defaults.string(forKey: armingDefaultsKey).flatMap(Arming.init(rawValue:))
    }

    // MARK: - Dismissal

    static func isDismissed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissedDefaultsKey)
    }

    /// The ✕. Per install, permanent, deliberately dies with a delete.
    static func markDismissed(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedDefaultsKey)
    }

    /// Hermetic UI-test seam: a hermetic boot is deterministic about the
    /// device, and the audit's pinned Dashboard subject must not gain a card
    /// no seed planted. Writes the `disarmed` decision outright.
    static func disarm(in defaults: UserDefaults = .standard) {
        defaults.set(Arming.disarmed.rawValue, forKey: armingDefaultsKey)
    }

    // MARK: - Display rule

    /// Which card, if any, a readiness state warrants — ignoring arming and
    /// dismissal. Pure so tests can pin the mapping without a store.
    ///
    /// `statuses` is `HKReadinessStore.writeAuthorizationStatuses`: WRITE
    /// types only, because Apple reports nothing for read types. "Nothing
    /// authorized" therefore means "no write type authorized", which is the
    /// strongest claim the platform lets anyone make — and exactly the state
    /// the field observation was in.
    static func variant(
        state: HKReadinessStore.ConnectionState,
        statuses: [String: HKReadinessStore.AuthStatus]
    ) -> Variant? {
        switch state {
        case .unknown, .fullyGranted:
            return nil
        case .notRequested, .denied:
            return .connect
        case .partiallyGranted:
            let anythingAuthorized = statuses.values.contains(.sharingAuthorized)
            return anythingAuthorized ? .newTypes : .connect
        }
    }

    /// The card's whole display rule: armed, not dismissed, and a state that
    /// warrants a variant. Deliberately blind to `isConnected`,
    /// `lastSyncedAt` and the banner's dismissal cooldown — superseding the
    /// `requestedAt` latch for this card's own display is the point, and the
    /// banner's rule stays untouched beside it.
    /// `sheetStatus` is the system's own answer for the candidate variant's
    /// request set (25-02, E-2026-08-29 #5): once it says ``SheetStatus/answered``,
    /// the card is done — detection, not memory. This is what the shipped
    /// `.fullyGranted`-only predicate could never do: Apple's sheet never
    /// re-asks a decided write type and never reports a read grant, so on the
    /// operator's device `.fullyGranted` was unreachable and the card
    /// survived its own completed flow. `.unknown` falls back to the state
    /// rule (25-01's exact behaviour) — the status only ever suppresses when
    /// the system affirmatively answers, it never invents a card.
    static func visibleVariant(
        state: HKReadinessStore.ConnectionState,
        statuses: [String: HKReadinessStore.AuthStatus],
        sheetStatus: SheetStatus = .unknown,
        defaults: UserDefaults = .standard
    ) -> Variant? {
        guard arming(in: defaults) == .armed else { return nil }
        guard !isDismissed(in: defaults) else { return nil }
        guard sheetStatus != .answered else { return nil }
        return variant(state: state, statuses: statuses)
    }
}
