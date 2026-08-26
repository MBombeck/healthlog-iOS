import Foundation

/// The `UserDefaults` slice the fresh-install guard reads and writes.
///
/// `UserDefaults` is not an implementation detail here — it *is* the
/// mechanism. iOS removes an app's defaults domain when the app is deleted
/// and deliberately keeps its Keychain items, so "the defaults carry no
/// install sentinel while the Keychain still carries a server address" is
/// precisely the signature of a deleted-and-reinstalled app. That asymmetry
/// is the spine of the rule — though not, as 13-05 found out, all of it.
///
/// The protocol exists so the rule can be exercised without a real defaults
/// domain and without a real Keychain: `FreshInstallGuard` never touches
/// either type directly.
///
/// **13-05** adds the second reading the rule turned out to need. The domain
/// does not only carry the sentinel; it also carries everything *older* builds
/// wrote into it, and iOS carries all of it across an update. Those older keys
/// are what separates "this app is new on this device" from "this sentinel is
/// new in this app" — two situations that look identical through
/// `installSentinel(forKey:)` alone. `carriesValue(forKey:)` asks the question
/// for any key of any type: a `Bool` written years ago is evidence exactly as
/// good as a `String`, so the check is presence, never value.
protocol InstallSentinelDefaults: AnyObject {
    func installSentinel(forKey key: String) -> String?
    func setInstallSentinel(_ value: String, forKey key: String)
    func carriesValue(forKey key: String) -> Bool
}

extension UserDefaults: InstallSentinelDefaults {
    func installSentinel(forKey key: String) -> String? {
        string(forKey: key)
    }

    func setInstallSentinel(_ value: String, forKey key: String) {
        set(value, forKey: key)
    }

    func carriesValue(forKey key: String) -> Bool {
        object(forKey: key) != nil
    }
}

/// **13-05.** Evidence, taken from the app's own container, that this
/// installation has been launched before.
///
/// A witness may only be read from a store iOS destroys together with the app.
/// Two stores are disqualified by construction, and both exclusions carry
/// weight:
///
/// - **The Keychain survives deletion.** It holds the very item the rule is
///   deciding about, so reading it as evidence would make the rule circular and
///   would restore precisely the K2 residue 13-01 removed.
/// - **The App Group container is shared with the widget and notification
///   extensions**, and its lifetime is not ours to promise. A witness that
///   outlived a delete would hand the next owner of a device the previous
///   owner's server address — the one outcome that must stay impossible.
protocol PriorLaunchWitnessing {
    /// `true` only on positive evidence. Every failure to look — an
    /// unresolvable directory, a denied read — answers `false`, because the
    /// safe direction for an unanswered question is the wipe: it costs a
    /// re-typed address, while a wrong `true` costs a stranger's server.
    func foundEvidenceOfPriorLaunch() -> Bool
}

/// The app's own store directory, `Library/Application Support/HealthLog`.
///
/// Every app-owned persistent store lives below it — `SWRCache`'s `Cache/`
/// (`SWRCache.swift:204-217`), the sandbox-fallback `Outbox/`, `Standalone/`,
/// `GLP1/`, `CoachChat/`, and the on-device briefing and trend files. Whichever
/// of them opens first creates it, and nothing removes it but the deletion of
/// the app: the recovery paths that do delete a store directory
/// (`SWRCacheFactory.swift:18-21`, `SWRCoordinator.swift:629-632`) delete
/// `HealthLog/Cache`, never its parent. So its presence means some earlier
/// launch got far enough to open a store, and its absence on a container that
/// has genuinely just been created is not a coincidence but a fact about
/// ordering: `LaunchPrologue` runs before `AppContainer` is composed, so on a
/// true first launch no store has opened yet.
///
/// It is checked, never created — `create: false`, and no directory is made.
/// A witness that manufactured its own evidence would answer "yes" on the first
/// launch of a genuinely fresh install and disarm the wipe for good.
struct ApplicationSupportPriorLaunchWitness: PriorLaunchWitnessing {
    /// Lock-step constant: the same directory name the store path builders
    /// append (`"HealthLog/Cache"`, `"HealthLog/Outbox"`, …). Duplicated as a
    /// bare string rather than reached through one of them so this type stays
    /// free of the SwiftData/store graph it is only observing.
    static let storeDirectoryName = "HealthLog"

    let directory: URL?
    let fileManager: FileManager

    static func production(fileManager: FileManager = .default) -> Self {
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(
            directory: appSupport?.appendingPathComponent(storeDirectoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    func foundEvidenceOfPriorLaunch() -> Bool {
        guard let directory else { return false }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

/// **13-01 (K2 tail).** Removes the server identity a *previous* installation
/// left behind in the Keychain, exactly once, on the first launch after an
/// install.
///
/// Why this is needed at all: `ServerURLStep` prefills its address field from
/// `AppEnvironment.currentBaseURL(keychain:)` → `KeychainKey.serverURL`.
/// Keychain items survive app deletion, so a user who deleted the app to
/// start clean was greeted by the previous owner's server address — the
/// operator's K2 observation on build 266. The shipped binary is neutral
/// (`scripts/verify-release-archive.sh:133-136,157` proves the archive
/// carries no operator host); what remained was device residue.
///
/// Scope is deliberately two keys, not the whole Keychain: the server
/// address and its explicit-host provenance fingerprint. The retirement
/// migration in `AppEnvironment.resolve` and its explicit-host sparing are
/// untouched — this guard is a fence in front of them, not a change to them.
enum FreshInstallGuard {
    /// UserDefaults key. Its *absence* is a signal only in company; on its own
    /// it means nothing (see ``wipeInheritedServerIdentityIfNeeded``). The
    /// value only records which generation of the rule wrote it.
    static let sentinelDefaultsKey = "hl.install.sentinel"
    static let sentinelValue = "1"

    /// **13-05.** Keys that builds *older than the sentinel* wrote into
    /// `UserDefaults.standard`. Any one of them present, with no sentinel
    /// beside it, is the signature of an installation that has been here all
    /// along and has just met the sentinel for the first time.
    ///
    /// The list is closed and explicit rather than a scan for the app's `hl.`
    /// prefix, and that is a safety property, not a style choice. A prefix scan
    /// reads whatever is in the domain at that instant — including the
    /// `NSArgumentDomain` a launch argument creates, and any key a future
    /// launch-time write lands before the prologue runs. Either would answer
    /// "this install is old" on a device where the app is new, and silently
    /// disarm the delete-and-reinstall wipe. A fixed list of keys that already
    /// existed cannot be polluted by anything written later.
    ///
    /// Why these four, in this order:
    ///
    /// - `hl.settings.darkDefault.reasserted.v1` — `SettingsStore.init` has
    ///   written it *unconditionally* on every launch since v0.14.7
    ///   (`SettingsStore.swift:222-228`), and `AppContainer` composes a
    ///   `SettingsStore` on every launch. This one alone covers every
    ///   installation that has run any build for roughly the last year.
    /// - `hl.syncMode` — `AuthStore.bootstrap` writes `.paired` for any install
    ///   holding a token (`AuthStore.swift:109`), and the onboarding choice
    ///   writes it for standalone. Every *authenticated* install has it, which
    ///   is exactly the population that owns a server address.
    /// - `hl.onboarding.mode` — written when the mode picker is answered, and
    ///   deliberately *not* cleared on logout.
    /// - `hl.settings.appearance` — written whenever an appearance is chosen or
    ///   re-asserted; the oldest of the four.
    static let defaultsKeysOlderThanTheSentinel = [
        "hl.settings.darkDefault.reasserted.v1",
        "hl.syncMode",
        "hl.onboarding.mode",
        "hl.settings.appearance"
    ]

    /// Which store answered. Reported so the outcome names its own evidence
    /// instead of asserting a conclusion.
    enum PriorLaunchWitness: String, Equatable, Sendable {
        /// A key from ``defaultsKeysOlderThanTheSentinel``.
        case defaultsKeyOlderThanTheSentinel
        /// `Library/Application Support/HealthLog`.
        case applicationSupportDirectory
    }

    enum Outcome: Equatable, Sendable {
        /// The sentinel was already present — an ordinary relaunch. Nothing
        /// was read from or written to the Keychain.
        case returningInstall
        /// **13-05.** No sentinel, but the container carries evidence of an
        /// earlier launch: this is the first launch after the *update* that
        /// introduced the sentinel, not after an install. The Keychain is left
        /// exactly as it was; only the sentinel is recorded.
        case preexistingInstall(witness: PriorLaunchWitness)
        /// No sentinel and no witness: this process is the first launch of
        /// this install.
        case freshInstall(wipedInheritedServerIdentity: Bool)
    }

    /// Runs the rule. Returns what it decided, so the launch prologue can
    /// record it without the guard needing to log or observe anything.
    ///
    /// **13-05 — why the sentinel's absence is not enough.** As 13-01 wrote it,
    /// this rule read a missing sentinel as proof of a deleted-and-reinstalled
    /// app. That inference is only sound once the sentinel has already shipped
    /// in some earlier build. On the build that *introduces* it — 267 — every
    /// installation in existence reads nil, because iOS keeps the defaults
    /// domain across an update and `hl.install.sentinel` had never been written
    /// into it. The rule therefore fired on every real device and deleted the
    /// server address it was written to protect. A missing sentinel is now the
    /// *first* of two premises; the second is that no store which dies with the
    /// app remembers an earlier launch.
    ///
    /// - Parameter containerWitness: the filesystem half of that second
    ///   premise. Defaulted so a call site that has no opinion still gets the
    ///   production witness; injected by tests, which must never let the host
    ///   process's own container decide a case.
    @discardableResult
    static func wipeInheritedServerIdentityIfNeeded(
        defaults: InstallSentinelDefaults,
        keychain: KeychainStoring,
        containerWitness: PriorLaunchWitnessing = ApplicationSupportPriorLaunchWitness.production()
    ) -> Outcome {
        guard defaults.installSentinel(forKey: sentinelDefaultsKey) == nil else {
            // An ordinary relaunch. Not one Keychain read, not one write —
            // a user mid-session must never lose the host they configured.
            return .returningInstall
        }
        if let witness = priorLaunchWitness(defaults: defaults, containerWitness: containerWitness) {
            // The install predates the sentinel. Nothing here is inherited from
            // a stranger; it is this user's own configuration, and it stays.
            // The sentinel is still written — see the note on the wipe branch:
            // the decision is taken once per install, whichever way it goes.
            defaults.setInstallSentinel(sentinelValue, forKey: sentinelDefaultsKey)
            return .preexistingInstall(witness: witness)
        }
        // No sentinel and nothing remembers an earlier launch: this process is
        // the first launch of this install. If the Keychain still carries a
        // server identity, it can only have come from a *previous* install of
        // this app on this device. Remove it.
        //
        // Provenance first, mirroring `AppEnvironment.setCustomBaseURL`'s
        // fail-closed order: if the second removal then fails, what is left
        // behind is an unconfirmed URL that the retirement migration can
        // still refuse — never a stale URL wearing a valid confirmation.
        //
        // Both keys go unconditionally: removing an absent item is a no-op,
        // and an orphaned fingerprint left behind by a half-failed write is
        // just as much residue of a previous install as the URL is.
        let inherited = keychain.getString(forKey: KeychainKey.serverURL)?.nilIfEmpty != nil
        try? keychain.remove(forKey: KeychainKey.serverURLExplicitHostFingerprint)
        try? keychain.remove(forKey: KeychainKey.serverURL)
        // The sentinel goes in last. A crash between the removal and this
        // write costs the next launch one more (idempotent) wipe of an
        // already-empty slot — the harmless direction.
        defaults.setInstallSentinel(sentinelValue, forKey: sentinelDefaultsKey)
        return .freshInstall(wipedInheritedServerIdentity: inherited)
    }

    /// **13-05.** The second premise: does any store that iOS destroys with the
    /// app remember an earlier launch?
    ///
    /// Two independent stores are asked, defaults first — it is the same domain
    /// the sentinel lives in, so it shares the sentinel's exact lifecycle, and
    /// it is the one that travels with an iCloud restore (the store
    /// directories below `Application Support/HealthLog` are marked
    /// `isExcludedFromBackup`, so a restored device may arrive without them).
    ///
    /// Asking two stores cannot make the delete-and-reinstall verdict wrong.
    /// Both are inside the app's data container; a deletion takes both. Adding
    /// witnesses can only ever turn a wrong "fresh" into a right "pre-existing"
    /// — which is why the answer is a union and not a quorum.
    static func priorLaunchWitness(
        defaults: InstallSentinelDefaults,
        containerWitness: PriorLaunchWitnessing
    ) -> PriorLaunchWitness? {
        if defaultsKeysOlderThanTheSentinel.contains(where: defaults.carriesValue(forKey:)) {
            return .defaultsKeyOlderThanTheSentinel
        }
        if containerWitness.foundEvidenceOfPriorLaunch() {
            return .applicationSupportDirectory
        }
        return nil
    }
}

/// The ordered launch prologue: everything that must happen, in a fixed
/// order, before the first `AppEnvironment.resolve` of the process.
///
/// It exists as its own seam because the *order* is the contract. A comment
/// saying "this runs first" is not a contract; a returned ledger that a test
/// can read is. `HealthLogApp.init` calls exactly this function, so the
/// ordering a test pins is the ordering the app runs.
@MainActor
enum LaunchPrologue {
    enum Step: String, Equatable, Sendable {
        case freshInstallGuard
        case uiTestOverrides
        case resolveEnvironment
    }

    struct Outcome {
        let environment: AppEnvironment
        /// The steps that actually ran, in the order they ran.
        let steps: [Step]
        /// What the fresh-install guard decided. Optional so a caller that
        /// composes a prologue without it stays representable; the app's own
        /// prologue always runs it.
        let freshInstall: FreshInstallGuard.Outcome?
    }

    /// - Parameters:
    ///   - applyUITestOverrides: the DEBUG-only UI-test seam
    ///     (`HealthLogApp.applyUITestEnvironmentOverrides`). Injected rather
    ///     than called directly so this file carries no `#if DEBUG` branch
    ///     and the test can drive the order without the seam.
    ///   - resolveEnvironment: `AppEnvironment.resolve`. Injected for the
    ///     same reason, and so a test can observe the Keychain *at the moment
    ///     resolve reads it* — the only honest way to assert "before".
    ///   - containerWitness: 13-05's filesystem witness. Required here, with no
    ///     default, because the prologue is the composition seam: a test that
    ///     forgot to inject one would silently let the host process's own
    ///     `Application Support` decide the case, and pass or fail for a reason
    ///     that has nothing to do with the code under test.
    static func run(
        defaults: InstallSentinelDefaults,
        keychain: KeychainStoring,
        containerWitness: PriorLaunchWitnessing,
        applyUITestOverrides: (KeychainStoring) -> Void,
        resolveEnvironment: (KeychainStoring) -> AppEnvironment
    ) -> Outcome {
        var steps: [Step] = []
        // First, always. Everything downstream — the UI-test seam, resolve,
        // and every `currentBaseURL` caller the resolved environment feeds —
        // must see a Keychain that no longer carries a stranger's server.
        let freshInstall = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            containerWitness: containerWitness
        )
        steps.append(.freshInstallGuard)
        // Second: the UI-test seam writes AFTER the wipe, so a seeded base URL
        // survives it. A seed that ran first would be erased by the guard.
        applyUITestOverrides(keychain)
        steps.append(.uiTestOverrides)
        let environment = resolveEnvironment(keychain)
        steps.append(.resolveEnvironment)
        return Outcome(environment: environment, steps: steps, freshInstall: freshInstall)
    }
}
