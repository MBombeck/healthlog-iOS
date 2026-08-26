import Foundation
@testable import HealthLog
import Testing

/// **13-01 (K2 tail).** iOS keeps Keychain items when an app is deleted and
/// throws the app's `UserDefaults` domain away. `ServerURLStep` prefills its
/// address field from the Keychain, so a user who deleted the app to start
/// clean was handed the previous owner's server address back.
///
/// These cases pin the rule that closes that: *defaults empty + Keychain
/// populated* is the deleted-and-reinstalled signature, and it must be acted
/// on before anything in the launch path reads a server address.
///
/// Cases 1 and 4 carry the `EXPECTED_RED` markers of 13-01: they were that
/// plan's two lies. An ordinary relaunch keeping its server and a genuine first
/// install recording only itself are their controls.
///
/// **13-05.** The rule as 13-01 wrote it had no second premise. "No sentinel"
/// is evidence of a first launch only once the sentinel has already shipped;
/// on the build that introduces it, every installation on earth reads nil.
/// `installOlderThanTheSentinelKeepsItsServer` is that missing case, and it is
/// the one the four above cannot express — each of them describes a world in
/// which the sentinel already exists, or in which nothing older than it does.
@Suite("Fresh-install sentinel (13-01)")
struct FreshInstallSentinelTests {
    private static let inheritedServer = "https://vorbesitzer.example.com"

    @Test("Ein gelöschtes und neu installiertes Exemplar erbt keine Serveradresse")
    func freshInstallWipesInheritedServerURL() throws {
        let defaults = InMemoryInstallSentinelDefaults()
        let keychain = InMemoryKeychain()
        let inherited = try #require(URL(string: Self.inheritedServer))
        // Written the way the app writes it: URL plus explicit-host
        // provenance, exactly what survives a delete-and-reinstall.
        try AppEnvironment.setCustomBaseURL(inherited, keychain: keychain)

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            // A container that remembers nothing, because a deleted app's
            // container is gone. Injected rather than defaulted: the host
            // process has an `Application Support` of its own, and letting it
            // answer would decide this case for a reason unrelated to the rule.
            containerWitness: StubContainerWitness.nothingOnDisk
        )

        #expect(
            keychain.getString(forKey: KeychainKey.serverURL) == nil
                && keychain.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) == nil,
            "EXPECTED_RED: a deleted-and-reinstalled app still inherits the previous server address"
        )
        #expect(outcome == .freshInstall(wipedInheritedServerIdentity: true))
        #expect(
            defaults.installSentinel(forKey: FreshInstallGuard.sentinelDefaultsKey)
                == FreshInstallGuard.sentinelValue
        )
    }

    @Test("Ein gewöhnlicher Neustart behält seinen Server")
    func returningLaunchKeepsConfiguredServer() throws {
        let defaults = InMemoryInstallSentinelDefaults()
        defaults.setInstallSentinel(
            FreshInstallGuard.sentinelValue,
            forKey: FreshInstallGuard.sentinelDefaultsKey
        )
        let keychain = InMemoryKeychain()
        let configured = try #require(URL(string: "https://meinserver.example.com"))
        try AppEnvironment.setCustomBaseURL(configured, keychain: keychain)

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            containerWitness: StubContainerWitness.nothingOnDisk
        )

        #expect(outcome == .returningInstall)
        #expect(keychain.getString(forKey: KeychainKey.serverURL) == configured.absoluteString)
        #expect(keychain.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) != nil)
    }

    /// **13-05 — the update path.** The installation that has been on this
    /// device all along, meeting the sentinel for the first time because the
    /// build it shipped in has just been installed *over* the previous one.
    ///
    /// iOS keeps the defaults domain across an update, so the domain still
    /// carries what older builds wrote into it — here
    /// `hl.settings.darkDefault.reasserted.v1`, which `SettingsStore.init` has
    /// written on every launch since v0.14.7 — while carrying no sentinel,
    /// because no build before 267 had one. That combination is not a fresh
    /// install. It is the opposite: proof that this container survived a
    /// previous launch.
    ///
    /// The assertion is deliberately behavioural rather than structural. It
    /// names what the user loses, not which branch the code takes, so it fails
    /// against the shipped rule instead of merely failing to compile against it.
    @Test("Eine Installation, die älter als der Sentinel ist, behält ihre Serveradresse")
    func installOlderThanTheSentinelKeepsItsServer() throws {
        let defaults = InMemoryInstallSentinelDefaults()
        // Written by a build that predates the sentinel. Same domain, same
        // lifecycle: iOS keeps it across an update and destroys it on delete.
        defaults.setInstallSentinel("1", forKey: "hl.settings.darkDefault.reasserted.v1")
        let keychain = InMemoryKeychain()
        let configured = try #require(URL(string: "https://meinserver.example.com"))
        try AppEnvironment.setCustomBaseURL(configured, keychain: keychain)

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            // Nothing on disk on purpose: the defaults key alone must carry
            // this verdict, or the case would prove only that the two witnesses
            // together happen to be enough.
            containerWitness: StubContainerWitness.nothingOnDisk
        )

        #expect(
            keychain.getString(forKey: KeychainKey.serverURL) == configured.absoluteString
                && keychain.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) != nil
                && outcome != .freshInstall(wipedInheritedServerIdentity: true),
            "EXPECTED_RED: the first launch of the sentinel-bearing build wipes the server address of an installation that predates the sentinel"
        )
        // Whichever way the decision goes, it is taken exactly once per
        // install: the sentinel is written on both branches, so the next launch
        // never asks again.
        #expect(
            defaults.installSentinel(forKey: FreshInstallGuard.sentinelDefaultsKey)
                == FreshInstallGuard.sentinelValue
        )
        #expect(outcome == .preexistingInstall(witness: .defaultsKeyOlderThanTheSentinel))
    }

    /// **13-05 — the other witness.** The same update path, seen from a
    /// defaults domain that happens to carry none of the four keys the rule
    /// knows by name. The container itself still remembers: some earlier launch
    /// opened a store under `Library/Application Support/HealthLog`, and that
    /// directory is inside the sandbox iOS destroys on delete.
    ///
    /// Two witnesses rather than one is not belt-and-braces for its own sake.
    /// The defaults domain rides an iCloud restore; the store directories are
    /// marked `isExcludedFromBackup` and may not. Either store answering is
    /// enough, and neither can survive a deletion — so the extra witness can
    /// only ever correct a wrong "fresh", never manufacture a wrong "old".
    @Test("Ein Container, der eine frühere Ausführung bezeugt, behält seine Serveradresse")
    func containerEvidenceAloneKeepsTheServer() throws {
        let defaults = InMemoryInstallSentinelDefaults()
        let keychain = InMemoryKeychain()
        let configured = try #require(URL(string: "https://meinserver.example.com"))
        try AppEnvironment.setCustomBaseURL(configured, keychain: keychain)

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            containerWitness: StubContainerWitness.anEarlierLaunch
        )

        #expect(outcome == .preexistingInstall(witness: .applicationSupportDirectory))
        #expect(keychain.getString(forKey: KeychainKey.serverURL) == configured.absoluteString)
        #expect(keychain.getString(forKey: KeychainKey.serverURLExplicitHostFingerprint) != nil)
        #expect(
            defaults.installSentinel(forKey: FreshInstallGuard.sentinelDefaultsKey)
                == FreshInstallGuard.sentinelValue
        )
    }

    /// **13-05.** When both stores can answer, the defaults domain is quoted.
    /// Not a preference between equals: it is the store the sentinel itself
    /// lives in, so it shares the sentinel's lifecycle exactly, and it is the
    /// one that survives a restore. The reported witness is evidence, so it has
    /// to be the strongest one available rather than whichever was asked last.
    @Test("Bezeugen beide Speicher, nennt das Ergebnis den Defaults-Zeugen")
    func defaultsWitnessIsQuotedBeforeTheContainer() {
        let defaults = InMemoryInstallSentinelDefaults()
        defaults.setInstallSentinel("dark", forKey: "hl.settings.appearance")

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: InMemoryKeychain(),
            containerWitness: StubContainerWitness.anEarlierLaunch
        )

        #expect(outcome == .preexistingInstall(witness: .defaultsKeyOlderThanTheSentinel))
    }

    @Test("Die echte Erstinstallation schreibt nur den Sentinel")
    func trueFirstInstallOnlyRecordsItself() {
        let defaults = InMemoryInstallSentinelDefaults()
        let keychain = InMemoryKeychain()

        let outcome = FreshInstallGuard.wipeInheritedServerIdentityIfNeeded(
            defaults: defaults,
            keychain: keychain,
            containerWitness: StubContainerWitness.nothingOnDisk
        )

        #expect(outcome == .freshInstall(wipedInheritedServerIdentity: false))
        #expect(keychain.getString(forKey: KeychainKey.serverURL) == nil)
        #expect(
            defaults.installSentinel(forKey: FreshInstallGuard.sentinelDefaultsKey)
                == FreshInstallGuard.sentinelValue
        )
    }

    /// **13-05 — the witness against a real file system**, because the whole
    /// rule now rests on what this type says about a directory.
    ///
    /// Three claims: an absent directory is not evidence, a present one is, and
    /// a *file* wearing the directory's name is not — a store that failed
    /// halfway must not be able to speak for a launch that never happened.
    /// Plus the property that matters most: asking the question never creates
    /// the answer.
    @Test("Der Container-Zeuge liest das Verzeichnis und legt es nie an")
    func applicationSupportWitnessReadsWithoutCreating() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hl-13-05-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let storeDirectory = root.appendingPathComponent(
            ApplicationSupportPriorLaunchWitness.storeDirectoryName,
            isDirectory: true
        )
        let witness = ApplicationSupportPriorLaunchWitness(
            directory: storeDirectory,
            fileManager: fileManager
        )

        #expect(witness.foundEvidenceOfPriorLaunch() == false)
        #expect(
            fileManager.fileExists(atPath: storeDirectory.path) == false,
            "the witness must never manufacture the evidence it looks for"
        )

        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        #expect(witness.foundEvidenceOfPriorLaunch())

        // A plain file under that name is residue, not a store directory.
        let fileRoot = root.appendingPathComponent("as-a-file", isDirectory: true)
        try fileManager.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        let impostor = fileRoot.appendingPathComponent(
            ApplicationSupportPriorLaunchWitness.storeDirectoryName,
            isDirectory: false
        )
        try Data().write(to: impostor)
        #expect(
            ApplicationSupportPriorLaunchWitness(directory: impostor, fileManager: fileManager)
                .foundEvidenceOfPriorLaunch() == false
        )

        // An unresolvable container answers "no evidence", never "yes".
        #expect(
            ApplicationSupportPriorLaunchWitness(directory: nil, fileManager: fileManager)
                .foundEvidenceOfPriorLaunch() == false
        )
        // The production witness looks below Application Support, at the app's
        // own store directory — and resolving it creates nothing either.
        #expect(
            ApplicationSupportPriorLaunchWitness.production().directory?.lastPathComponent
                == ApplicationSupportPriorLaunchWitness.storeDirectoryName
        )
    }

    /// The ordering claim, asserted twice over: from the prologue's own ledger
    /// and from what the Keychain looked like *at the instant* resolve read
    /// it. A ledger alone could be reordered without moving the work; the
    /// observation alone could pass by accident on an empty Keychain.
    @MainActor
    @Test("Der Erstlauf-Wisch liegt vor jedem AppEnvironment.resolve")
    func sentinelGuardRunsBeforeResolve() throws {
        let defaults = InMemoryInstallSentinelDefaults()
        let keychain = InMemoryKeychain()
        let inherited = try #require(URL(string: Self.inheritedServer))
        try AppEnvironment.setCustomBaseURL(inherited, keychain: keychain)

        var serverURLSeenByResolve: String?
        let outcome = LaunchPrologue.run(
            defaults: defaults,
            keychain: keychain,
            containerWitness: StubContainerWitness.nothingOnDisk,
            applyUITestOverrides: { _ in },
            resolveEnvironment: { keychain in
                serverURLSeenByResolve = keychain.getString(forKey: KeychainKey.serverURL)
                return AppEnvironment.resolve(
                    keychain: keychain,
                    bundle: Bundle(for: FreshInstallBundleAnchor.self)
                )
            }
        )

        #expect(
            outcome.steps.first == .freshInstallGuard && serverURLSeenByResolve == nil,
            "EXPECTED_RED: nothing orders the wipe before AppEnvironment.resolve"
        )
        #expect(outcome.steps == [.freshInstallGuard, .uiTestOverrides, .resolveEnvironment])
        #expect(outcome.environment.baseURL == nil)
    }
}

/// Anchor for a bundle that does not set `HLBaseURL` — the honest
/// "no server configured" case.
private final class FreshInstallBundleAnchor {}

/// **13-05.** The filesystem half of the rule, stated rather than discovered.
/// The real witness is exercised against a real directory in
/// `applicationSupportWitnessReadsWithoutCreating`; everywhere else the answer
/// is a premise of the case, because a test that let the host process's own
/// container decide would pass or fail for reasons outside the code.
private struct StubContainerWitness: PriorLaunchWitnessing {
    static let nothingOnDisk = StubContainerWitness(evidence: false)
    static let anEarlierLaunch = StubContainerWitness(evidence: true)

    let evidence: Bool

    func foundEvidenceOfPriorLaunch() -> Bool {
        evidence
    }
}

private final class InMemoryInstallSentinelDefaults: InstallSentinelDefaults {
    private var storage: [String: String] = [:]

    func installSentinel(forKey key: String) -> String? {
        storage[key]
    }

    func setInstallSentinel(_ value: String, forKey key: String) {
        storage[key] = value
    }

    /// Models "this domain carries a value under that key, whatever its type" —
    /// the question the 13-05 witness asks about keys older builds wrote. The
    /// double stores strings only; what matters to the rule is presence.
    func carriesValue(forKey key: String) -> Bool {
        storage[key] != nil
    }
}
