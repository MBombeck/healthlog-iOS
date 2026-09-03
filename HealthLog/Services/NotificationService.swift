//
// File-length budget — the notification service composes APNs token
// registration, UN delegate, category registry, action dispatch,
// medication intake roundtrip, local-reminder scheduling helpers,
// snooze re-schedule, hex helpers. v0.5.5 W-MED added the
// medication-userInfo single-source helper to keep the local-fallback
// orchestrator from re-implementing the formatter. Splitting further
// goes into +LocalBackups, +SmartReminder, +MoodActions extensions.
import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// Public Service für alle UNUserNotifications- + APNs-Aspekte. Konformiert
    /// `AppDelegateBridge` damit `AppDelegate` UIKit-Callbacks an uns weiterreichen
    /// kann. Konformiert `UNUserNotificationCenterDelegate` für Foreground-
    /// Banner + Tap-Routing.
    ///
    /// Konzeption:
    /// - Token-Registrierung ist idempotent: gleiche `(tokenHex, env)` ⇒ kein
    ///   doppelter `/api/devices`-POST. Server toleriert Duplicates trotzdem
    ///   (Upsert), aber wir sparen Netz.
    /// - Foreground-Delivery zeigt Banner + Sound — Medikamenten-Reminder sind
    ///   zeit-kritisch, ein silent-swallow wäre User-feindlich.
    /// - 409 von `/api/devices` (Token bereits an anderen User vergeben) wird
    ///   geloggt + `lastRegistration` trotzdem gemerkt, damit wir nicht in den
    ///   Loop gehen. Server-side tote Tokens werden über den APNs-Feedback-
    ///   Channel beim nächsten Send-Versuch gedropped.
    @MainActor
    final class NotificationService: NSObject, AppDelegateBridge {
        private let api: APIClientProtocol
        private let environment: AppEnvironment
        private let keychain: KeychainStoring
        /// `internal` (not `private`) so the mood-action extension in
        /// `NotificationService+MoodActions.swift` can route to the
        /// quick-entry sheet without a wrapper indirection. The router
        /// is a reference type so this leaks no ownership semantics.
        let deepLinks: DeepLinkRouter
        let backgroundSync: BackgroundSyncCoordinator?
        /// Medications repository — wired from `AppContainer` so the
        /// notification action handler can POST a server-roundtrip on
        /// "Genommen" / "Übersprungen" without bouncing through a store
        /// that may not have the affected `todayIntakes` row loaded. The
        /// repo owns its own outbox-enqueue path for retriable errors,
        /// so an offline tap on "Genommen" still lands eventually.
        /// Optional for tests + macOS build paths.
        let medicationsRepo: MedicationsRepository?

        /// UserDefaults backing for the `LastRegistrationSnapshot`. Injected
        /// so tests can swap to an isolated suite without bleeding into
        /// `.standard`. Production wires `.standard`.
        let defaults: UserDefaults

        struct RegistrationState: Equatable {
            let tokenHex: String
            let env: APNsEnvironment
            /// W-B189 (#22) — the Live-Activity push token sent alongside the
            /// APNs token. Part of the dedup key so a *new* LA token re-fires
            /// `POST /api/devices` (the server needs the current token to push
            /// the running Activity), but an unchanged LA token does not spam.
            let liveActivityPushToken: String?
        }

        var lastRegistration: RegistrationState?

        /// v0.8.4 WWIDGET-1 — latest ActivityKit push-to-start token (hex).
        /// Cached so the wiring is exercised on-device; forwarded to the
        /// server via `POST /api/devices` `liveActivityPushToken` once a
        /// running Activity has no per-activity update token yet (W-B189 /
        /// #22; see `NotificationService+LiveActivity.swift`). Not persisted —
        /// a fresh token is delivered each launch the controller subscribes.
        var liveActivityPushToStartToken: String?

        /// v0.8.4 WWIDGET-1 — latest per-activity update tokens (hex) keyed
        /// by medication id. Same lifecycle + forwarding note as
        /// ``liveActivityPushToStartToken``.
        var liveActivityUpdateTokens: [String: String] = [:]

        /// **v0.6.1.3 Y4.1 — App-Badge accessor.**
        /// Lazy accessor for `MedicationsStore` so the `willPresent`
        /// delegate hook can recompute the badge without a build-time
        /// import cycle. Wired from `AppContainer.init` once the store
        /// has been built. `nil` in headless tests + macOS builds.
        var medicationsStoreAccessor: (@MainActor () -> MedicationsStore?)?

        /// **v0.14.1 notifications-bug H2 — "already logged today?" accessor.**
        /// Lazy read of the live `MoodStore` for the foreground `willPresent`
        /// delegate hook. The evening mood reminder is now a *repeating* daily
        /// trigger (it survives background with no re-arm), so the "don't nag if
        /// the user already logged today" gate can no longer live in the
        /// scheduling step — it moves here: when the reminder arrives in the
        /// foreground and a mood entry already exists for today, `willPresent`
        /// suppresses the banner. Returns `false` when unwired (headless tests /
        /// macOS builds) so a missing accessor never suppresses a real med
        /// reminder. Wired from `AppContainer.configureRuntimeWiring`.
        var moodLoggedTodayAccessor: (@MainActor () -> Bool)?

        /// **v1.18.6 (#32) — Vorsorge reminder server-completion seam.**
        /// Wired from `AppContainer` so the foreground "Erledigt" action can POST
        /// `…/{id}/complete` (server-authoritative) without an import cycle on the
        /// `MeasurementRemindersStore`. Returns `true` when the server call
        /// succeeded. `nil` in headless tests / macOS builds → the handler falls
        /// back to the capture deep-link, which is also the path when the push
        /// carries no resolvable `reminderId`.
        var measurementReminderCompleter: (@MainActor (String) async -> Bool)?

        /// v0.6.0.8 — operator-facing diagnostic of the last
        /// `POST /api/devices` attempt. Mirrored to UserDefaults so a
        /// crashed/restarted app still surfaces the most recent state in
        /// `NotificationDiagnosticsScreen`. PII discipline: only the
        /// first 8 + last 8 hex chars of the APNs token are persisted,
        /// never the full 128-char string.
        var lastRegistrationSnapshot: LastRegistrationSnapshot?

        /// UserDefaults key for `lastRegistrationSnapshot`. Versioned `v1`
        /// so future schema changes can migrate forward without losing
        /// the existing operator-debug surface in one release.
        static let lastRegistrationDefaultsKey = "dev.healthlog.app.notif.lastRegistration.v1"

        /// The instance that owns the `UNUserNotificationCenter` delegate slot.
        ///
        /// `AppContainer.init` (from `HealthLogApp.init`) constructs this service
        /// BEFORE UIKit runs `application(_:willFinishLaunchingWithOptions:)`.
        /// Spezi's `SpeziAppDelegate` then installs its own
        /// `SpeziNotificationCenterDelegate` there whenever a configured module
        /// conforms to `NotificationHandler` — `SchedulerNotifications` does — and
        /// silently takes the slot away from us. `HealthLogSpeziDelegate` calls
        /// ``reinstallNotificationCenterDelegate()`` right after `super` returns
        /// to hand it back; without that every banner action is a no-op.
        private(set) nonisolated(unsafe) weak static var installedDelegate: NotificationService?

        /// Re-install the app's `NotificationService` as the notification-center
        /// delegate. Returns `false` when no service has been constructed yet
        /// (the `init` above installs itself in that case, so the later of the
        /// two always wins for the app).
        @discardableResult
        nonisolated static func reinstallNotificationCenterDelegate() -> Bool {
            guard let installed = installedDelegate else { return false }
            UNUserNotificationCenter.current().delegate = installed
            return true
        }

        init(
            api: APIClientProtocol,
            environment: AppEnvironment,
            keychain: KeychainStoring,
            deepLinks: DeepLinkRouter,
            backgroundSync: BackgroundSyncCoordinator? = nil,
            medicationsRepo: MedicationsRepository? = nil,
            defaults: UserDefaults = .standard
        ) {
            self.api = api
            self.environment = environment
            self.keychain = keychain
            self.deepLinks = deepLinks
            self.backgroundSync = backgroundSync
            self.medicationsRepo = medicationsRepo
            self.defaults = defaults
            super.init()
            UNUserNotificationCenter.current().delegate = self
            Self.installedDelegate = self
            registerCategories()
            lastRegistrationSnapshot = Self.loadLastRegistration(from: defaults)
        }

        // MARK: - Permissions

        /// The full `UNAuthorizationOptions` set we ask the user for.
        ///
        /// **Time-Sensitive note:** iOS 15 deprecated the
        /// `.timeSensitive` `UNAuthorizationOption` — the system now
        /// surfaces the Settings → HealthLog → Notifications → "Time-
        /// Sensitive Notifications" toggle whenever the app ships the
        /// entitlement `com.apple.developer.usernotifications.time-
        /// sensitive` (set in `HealthLog.entitlements`). The entitlement
        /// alone is the contract — adding the deprecated option would
        /// emit a compile error under `warnings-as-errors`. Without the
        /// entitlement the system silently demotes every
        /// `content.interruptionLevel = .timeSensitive` banner back to
        /// `.active`, so medication reminders would not break through
        /// Focus / DND.
        ///
        /// Exposed as a `static` helper so tests can pin the option set
        /// without needing to drive the real `UNUserNotificationCenter`.
        static func authorizationOptions(allowCriticalAlerts: Bool) -> UNAuthorizationOptions {
            var options: UNAuthorizationOptions = [.alert, .sound, .badge, .providesAppNotificationSettings]
            if allowCriticalAlerts { options.insert(.criticalAlert) }
            return options
        }

        @discardableResult
        func requestAuthorization(allowCriticalAlerts: Bool = false) async -> Bool {
            let options = Self.authorizationOptions(allowCriticalAlerts: allowCriticalAlerts)
            let granted = await (try? UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
            HLLog.notifications.info("UNAuth-Request abgeschlossen — granted=\(granted)")
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        }

        func currentSettings() async -> UNNotificationSettings {
            await UNUserNotificationCenter.current().notificationSettings()
        }

        /// Best-effort. Wenn UNAuth bereits granted ist, registrieren wir direkt
        /// (ohne System-Prompt zu zeigen). Sonst nichts. Aufgerufen von der
        /// Re-Registration-Foreground-Logik in `AppContainer`.
        func registerForRemoteNotificationsIfAuthorized() async {
            let settings = await currentSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                UIApplication.shared.registerForRemoteNotifications()
            case .denied, .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Device registration POST

    extension NotificationService {
        /// Builds + sends the `POST /api/devices` body. Split into this
        /// extension (W-B189) to keep the core type body under the
        /// `type_body_length` budget — same file, so the private `keychain` /
        /// `environment` / `api` members stay reachable.
        ///
        /// W-B189 (#22): `liveActivityPushToken` rides alongside the APNs token
        /// so the server (≥ v1.17.1) can push a running medication Live Activity
        /// directly. Omitted from the JSON body when `nil` (see
        /// `DeviceRegistration.encode(to:)`).
        func postDevice(
            tokenHex: String,
            env: APNsEnvironment,
            liveActivityPushToken: String?
        ) async throws {
            let deviceUUID = (try? keychain.deviceID()) ?? UUID().uuidString.lowercased()
            let body = DeviceRegistration(
                token: deviceUUID,
                bundleId: environment.bundleID,
                locale: Locale.current.identifier,
                appVersion: environment.appVersion,
                model: Self.deviceModel(),
                apnsToken: tokenHex,
                apnsEnvironment: env,
                liveActivityPushToken: liveActivityPushToken
            )
            let req: APIRequest<EmptyPayload> = try .post("/api/devices", body: body)
            try await api.sendVoid(req)
        }

        static func deviceModel() -> String {
            UIDevice.current.model
        }
    }

    // MARK: - LastRegistrationSnapshot (v0.6.0.8 audit)

    extension NotificationService {
        /// Operator-facing audit blob describing the last `POST /api/devices`
        /// attempt. Persisted to UserDefaults so the diagnostics surface
        /// survives a crash/restart.
        ///
        /// **PII discipline:** the persisted snapshot stores only the first
        /// 8 + last 8 hex chars of the APNs token (`tokenPrefix` /
        /// `tokenSuffix`). The full 128-char string is retained in memory
        /// solely so `forceRefreshRegistration()` can re-issue a POST without
        /// waiting for Apple to deliver a fresh token — it is **never**
        /// written to UserDefaults. A snapshot read off disk will have
        /// `fullTokenHex == nil`, which forces the force-fresh button to
        /// wait until the OS delivers a token after the first foreground.
        struct LastRegistrationSnapshot: Codable, Equatable {
            /// First 8 hex of the APNs token. `nil` until the OS has
            /// delivered a token at least once. 8 chars carry enough
            /// entropy for an operator to correlate with the server log
            /// row without leaking the full credential.
            var tokenPrefix: String?
            /// Last 8 hex of the APNs token. Mirrors `tokenPrefix`.
            var tokenSuffix: String?
            /// `sandbox` / `production` — string raw value of `APNsEnvironment`
            /// so the codable shape stays decoupled from the framework enum
            /// (forward-compat against future cases).
            var environment: String?
            /// Timestamp of the most recent `register(...)` entry —
            /// includes dedup short-circuits so the operator can see the
            /// registration loop ran even when no network call happened.
            var lastRegistrationAttemptAt: Date?
            /// HTTP status from the last `POST /api/devices` attempt.
            /// `nil` when no network call happened (dedup) or when the
            /// request never reached the server (URLError before response).
            var lastRegistrationServerStatus: Int?
            /// Sanitized error message from the last failed attempt.
            /// Passed through `LogSanitizer.redact` before persisting so
            /// PII (auth headers, tokens, UUIDs, emails) is scrubbed.
            var lastRegistrationError: String?
            /// In-memory shadow of the full token. Excluded from the codable
            /// shape (`CodingKeys` skips it) so a disk-roundtrip drops it —
            /// the persisted blob keeps only the truncated prefix/suffix.
            var fullTokenHex: String?

            var hasToken: Bool {
                fullTokenHex != nil
            }

            mutating func setToken(hex: String) {
                fullTokenHex = hex
                tokenPrefix = String(hex.prefix(8))
                tokenSuffix = hex.count > 8 ? String(hex.suffix(8)) : nil
            }

            /// Persisted fields only — `fullTokenHex` is intentionally
            /// excluded so a disk-roundtrip drops the full token.
            enum CodingKeys: String, CodingKey {
                case tokenPrefix
                case tokenSuffix
                case environment
                case lastRegistrationAttemptAt
                case lastRegistrationServerStatus
                case lastRegistrationError
            }

            init(
                tokenPrefix: String? = nil,
                tokenSuffix: String? = nil,
                environment: String? = nil,
                lastRegistrationAttemptAt: Date? = nil,
                lastRegistrationServerStatus: Int? = nil,
                lastRegistrationError: String? = nil,
                fullTokenHex: String? = nil
            ) {
                self.tokenPrefix = tokenPrefix
                self.tokenSuffix = tokenSuffix
                self.environment = environment
                self.lastRegistrationAttemptAt = lastRegistrationAttemptAt
                self.lastRegistrationServerStatus = lastRegistrationServerStatus
                self.lastRegistrationError = lastRegistrationError
                self.fullTokenHex = fullTokenHex
            }
        }
    }

    // MARK: - Hex helpers

    extension Data {
        /// Lowercase-hex-Encoding für APNs-Token-Bytes. 64-Byte-Token →
        /// 128-Char-String. Server's Zod-Schema erlaubt beide Cases (`/^[A-Fa-f0-9]+$/`)
        /// — wir senden konsistent lowercase, damit Logs nach Diff-Vergleichen
        /// nicht zwischen Cases wackeln.
        func hexEncodedString() -> String {
            map { String(format: "%02x", $0) }.joined()
        }
    }

#endif
