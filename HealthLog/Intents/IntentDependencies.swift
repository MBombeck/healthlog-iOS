import Foundation

/// **v0.7.1 W-APPINTENTS** — minimal dependency resolver for App Intents.
///
/// App Intents run **outside** a full app launch — Siri / Spotlight /
/// Shortcuts invoke `perform()` in a lightweight extension-like context
/// where the SwiftUI `AppContainer` (BGTask registration, SWR cache
/// open, store fan-out) is neither up nor needed. Standing up the whole
/// composition root from an intent would be both wasteful and risky
/// (BGTaskScheduler must register inside `didFinishLaunching`, which the
/// intent context isn't).
///
/// Instead we resolve the **same** repositories the app + the
/// notification action handler use — `MeasurementsRepository.create` and
/// `MedicationsRepository.recordFromReminder` — from the persistent
/// pieces only: the Keychain (auth token + server URL) and a recovered
/// Outbox. Writes therefore travel the identical server-first, optimistic,
/// idempotency-keyed, outbox-on-failure path. No parallel write path is
/// introduced.
///
/// **Auth:** `APIClient` reads the bearer token straight from the
/// Keychain on every request build, so an intent that resolves a fresh
/// `APIClient` is authenticated exactly when the user is signed in. When
/// no token is present the repo call 401s and the intent surfaces a
/// "sign in first" dialog rather than silently dropping the write.
///
/// **Outbox (audit-v0162 H2):** `OutboxQueue.makeWithRecovery()` opens the
/// outbox store in the **shared App Group container**
/// (`group.dev.healthlog.app`, see `OutboxStore.persistentStoreURL()`). When
/// this resolver runs inside the widget / Live-Activity extension process, that
/// is the *same* on-disk store the app opens — so a write that hits a network
/// error from an intent is durably enqueued into the one shared outbox and
/// replayed by the **app's** `OutboxReplayService` on the next foreground /
/// reachability tick, exactly-once via the shared idempotency key. The
/// extension only ever *appends* here; the app owns the drain (see the
/// concurrency note on `OutboxStore.persistentStoreURL()`). Before the fix the
/// extension enqueued into its own process-local sandbox outbox that nothing
/// ever drained, and offline "Genommen"/mood taps were permanently lost.
@MainActor
enum IntentDependencies {
    /// Resolve the shared dependency bundle for an intent perform. Cached
    /// for the (short) lifetime of the intent process so two parameter
    /// resolutions in one invocation don't re-open the Outbox store.
    static func resolve() -> Resolved {
        if let testOverride { return testOverride }
        if let cached { return cached }
        let keychain = KeychainStore()
        let environment = AppEnvironment.resolve(keychain: keychain)
        let pinner = CertificatePinner(fromBundle: .main)

        // Security audit H1 — dieselbe Bedingung wie im App-Composition-Root
        // (`AppContainer.makeCoreInfra`), nur fuer die EXTENSION: `Bundle.main`
        // ist hier das Extension-Bundle, also faengt der Guard genau deren
        // eigene Pins ab. Die intents `perform()` schicken den geteilten
        // Bearer-Token + PHI (Medikamenteneinnahme, Blutdruck, Glukose,
        // Stimmung, Messwerte) an den eingerichteten Server.
        //
        // Ein Build OHNE Pinning ist gueltig (Selbst-Hoster ohne Pins →
        // System-Trust) und darf nicht crashen. Kaputt ist ein Build, der
        // Pinning deklariert und es unvollstaendig mitbringt — insbesondere
        // eine Extension-Info.plist, die die Pins des App-Targets nicht
        // gespiegelt hat.
        #if !DEBUG
            precondition(
                pinner.pinConfigurationIsValid,
                """
                Release-Extension mit unvollstaendiger TLS-Pin-Konfiguration gestartet \
                (\(pinner.pinnedHostSuffixes.count) Hosts, \(pinner.pinnedSPKIHashes.count) Pins, \
                well-formed: \(pinner.pinsAreWellFormed)). Wer pinnt, braucht beides: mindestens einen \
                Host in HLPinnedHosts UND mindestens \(CertificatePinner.minimumProductionPinCount) Pins \
                (Primaer + Backup) als 32-Byte-SHA-256-base64 in HLPinnedSPKIHashes — der \
                HealthLogWidgets-Block in Config/local.yml muss byte-gleich zum App-Target sein.
                """
            )
        #endif

        let api = APIClient(
            environment: environment,
            keychain: keychain,
            pinner: pinner
        )
        let outbox = OutboxQueue.makeWithRecovery()
        let resolved = Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        cached = resolved
        return resolved
    }

    /// `true` when an auth token is present — the intents gate on this so
    /// they can surface a "sign in first" dialog instead of firing a
    /// doomed 401.
    static func isSignedIn(_ resolved: Resolved) -> Bool {
        resolved.keychain.getString(forKey: KeychainKey.authToken) != nil
    }

    private static var cached: Resolved?

    /// **Test seam.** When set, `resolve()` returns this bundle instead
    /// of building the live one — lets the intent `perform()` tests run
    /// against a stub `APIClient` + in-memory Outbox without standing up
    /// the Keychain / network. Production never sets this.
    static var testOverride: Resolved?

    struct Resolved {
        let keychain: KeychainStoring
        let api: APIClientProtocol
        let outbox: OutboxQueue
        let measurementsRepo: MeasurementsRepository
        let medicationsRepo: MedicationsRepository
        let moodRepo: MoodRepository

        init(
            keychain: KeychainStoring,
            api: APIClientProtocol,
            outbox: OutboxQueue,
            measurementsRepo: MeasurementsRepository,
            medicationsRepo: MedicationsRepository,
            moodRepo: MoodRepository
        ) {
            self.keychain = keychain
            self.api = api
            self.outbox = outbox
            self.measurementsRepo = measurementsRepo
            self.medicationsRepo = medicationsRepo
            self.moodRepo = moodRepo
        }
    }
}
