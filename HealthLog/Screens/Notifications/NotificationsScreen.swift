//
// The /settings/notifications shell. Card subviews live in
// `NotificationsScreen+Cards.swift` / `+ChannelCards.swift`; interaction
// logic in `+Logic.swift` (file_length discipline). The residual `body` +
// `@State` props stay here.
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// Settings → Benachrichtigungen. Per APNs-Channel zeigt die Liste alle vom
/// Server bekannten Event-Types als Toggles, geordnet nach UX-Priorität.
///
/// **v0.4.0 Polish (A7 §3 / user-report #11):**
/// - Section-Ordering nach Priorität (`NotificationEventPriority`), nicht
///   Server-Order. Daily-Briefing → Records → Medikamente → System.
///   (v0.5.0+ R1: Streak-Erinnerung wurde komplett aus dem iOS-Client
///   entfernt — siehe master-prompt.)
/// - Empty-State je Channel, falls keine Events enabled sind.
/// - "Letzte Zustellung" pro Channel via `/api/notifications/status`.
/// - "Test-Benachrichtigung senden"-Button — feuert eine lokale `UNNotificationRequest`
///   (zero server work, testet was der User real wissen will: ist meine Permission +
///   Wiring OK?). Server-side `/api/notifications/test` ist nicht vorhanden;
///   A7 §3.4 empfiehlt local-only für v0.4.0.
/// - `hlScreenBackground()` für canonical color.
///
/// Bei System-deny: Footer-Link auf `UIApplication.openSettingsURLString`
/// damit der User die Permission im iOS-Settings-Bundle re-enable kann
/// (Apple zeigt den System-Prompt nur einmal pro Install).
struct NotificationsScreen: View {
    @Environment(\.appContainer) var container
    /// QoL-A2 (Felt-craft #5) — gate the test-confirmation auto-dismiss fade
    /// on reduce-motion (app-wide "ALWAYS reduce-motion-gated" doctrine).
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var store: NotificationsStore?
    /// v0.14.2 FW7 — per-user notification-channel settings (ntfy + Telegram).
    /// Server-first, gated by `/api/settings/global-services`. Built lazily in
    /// `initializeStore` off the same `container.api` as the APNs store.
    @State var servicesStore: NotificationServicesStore?
    @State var systemAuthorizationStatus: NotificationsSystemStatus = .unknown
    /// v0.5.4.3 HP5 — tracks the in-flight mood-reminder toggle PATCH so
    /// the UI can show a subtle progress glyph while the server confirms.
    @State var moodReminderInFlight: Bool = false
    /// MED-4 / C3 — in-flight guard while a low-supply threshold PATCH is in
    /// flight, so a rapid re-toggle / re-step can't fire overlapping writes.
    @State var lowStockInFlight: Bool = false
    /// W-B189 (#23) — in-flight guard while the preventive-care reminder opt-in
    /// PATCH is in flight, so a rapid re-toggle can't fire overlapping writes.
    @State var measurementReminderInFlight: Bool = false
    /// MED-4 / C3 — the stepper's working value while the alert is on. Seeded
    /// from the store's threshold (or the server default 7) on appear, so a
    /// flip-on lands a sensible starting value the user can then tune.
    @State var lowStockDaysSelection: Int = medicationLowStockRunwayDefault
    /// v0.10.0 W-Mood-B — locally-selected evening reminder hour (0–23). `nil`
    /// until the user picks a time; the picker then falls back to the
    /// store's server-mirrored hour.
    @State var moodReminderHourSelection: Int?
    @State var lastTestSentAt: Date?
    /// Bumped on every test-push tap — drives `.sensoryFeedback(.success)`
    /// and the auto-dismiss timer for the confirmation row. Counter rather
    /// than `Bool` so back-to-back taps both fire the haptic and reset the
    /// fade timer.
    @State var testTapCount: Int = 0
    /// Auto-dismiss task for the confirmation row. Cancelled when the user
    /// fires a new tap so we don't overlap timers.
    @State var confirmationDismissTask: Task<Void, Never>?
    /// Last test-push variant the user picked — surfaced in the confirmation
    /// row so they know which payload-shape was sent. `nil` = no test sent
    /// yet in this session.
    @State var lastTestVariant: TestPushVariant?
    /// W-B188 (AUDIT-SEC-b187 High) — device-local "hide medication name on
    /// lock screen" opt-out. Seeded from `LockScreenPrivacy` on appear; the
    /// toggle persists via the same helper. Default OFF (real name shown).
    @State var hideMedicationNameOnLockScreen: Bool = LockScreenPrivacy.hideMedicationName()
    /// **W-THRESHOLD-NUDGE** — device-local opt-in for the MDR-safe out-of-range
    /// nudge. Seeded from `ThresholdNudgePrefStore` on appear; the toggle
    /// persists via the same helper. Default OFF (opt-in).
    @State var outOfRangeNudgeEnabled: Bool = ThresholdNudgePrefStore.isEnabled()

    var body: some View {
        // W1-5 / R5 #2 — converted from a multi-section `List` to the
        // `HLSettingsPage + HLSettingsCard` rhythm so the Notifications
        // sub-screen reads identical to every other Settings sub-screen
        // (Konto, Integrationen etc.). Every preserved row + toggle +
        // button stays — the envelope changes from `Section{} header{}
        // footer{}` to `HLSettingsCard(icon:title:footer:)`.
        HLSettingsPage(title: "Notifications") {
            systemPermissionCard
            channelsCard
            serviceChannelCards
            moodReminderCard
            lowStockCard
            measurementReminderCard
            outOfRangeNudgeCard
            preferencesCards
            focusFilterInfoCard
            lockScreenPrivacyCard
            testPushCard
            systemSettingsCard
            // v0.14.8 W2-SYNCUX — canonical sync-status footer (same
            // primitive as Dashboard/Insights, self-suppressing).
            HLSyncStatusFooter(screenLoading: store?.isLoading == true)
        }
        .navigationTitle("Notifications")
        // SET-V2-C (C-5) — pushed from the Settings hub; sub-screen canon is `.inline`.
        .navigationBarTitleDisplayMode(.inline)
        .task { await initializeStore() }
        .refreshable {
            await store?.load()
            await servicesStore?.load()
        }
        .sensoryFeedback(.success, trigger: testTapCount)
        .alert(
            "Error",
            isPresented: Binding(
                get: { store?.error != nil },
                set: { if !$0 { store?.error = nil } }
            ),
            presenting: store?.error
        ) { _ in
            Button("OK") { store?.error = nil }
        } message: { err in
            // v0.14.1 #3 — never leak raw server text (e.g. a JS TypeError
            // "x.map is not a function") into the alert. `userFacingDescription`
            // returns a generic "Server error…" for 5xx and only surfaces the
            // server message for 4xx envelopes.
            Text(err.userFacingDescription)
        }
    }
}

// MARK: - System status mapping

enum NotificationsSystemStatus: Equatable {
    case unknown
    case authorized
    case provisional
    case denied
    case notDetermined

    #if canImport(UserNotifications)
        init(authorization: UNAuthorizationStatus) {
            switch authorization {
            case .authorized: self = .authorized
            case .provisional: self = .provisional
            case .denied: self = .denied
            case .notDetermined: self = .notDetermined
            case .ephemeral: self = .provisional
            @unknown default: self = .unknown
            }
        }
    #endif

    var symbol: String {
        switch self {
        case .authorized, .provisional: "checkmark.shield.fill"
        case .denied: "xmark.shield.fill"
        case .notDetermined, .unknown: "questionmark.shield"
        }
    }

    var tint: Color {
        // Monochrome doctrine: the shield glyph (checkmark / xmark /
        // questionmark) carries the authorisation state — no coloured
        // bubble. Authorised reads at full ink, the rest sit muted.
        switch self {
        case .authorized, .provisional: HLText.primary
        case .denied, .notDetermined, .unknown: HLText.secondary
        }
    }

    var title: String {
        switch self {
        case .authorized: String(localized: "Push notifications active")
        case .provisional: String(localized: "Provisionally active")
        case .denied: String(localized: "Push notifications blocked")
        case .notDetermined: String(localized: "Not decided yet")
        case .unknown: String(localized: "Status unknown")
        }
    }

    var subtitle: String {
        switch self {
        case .authorized: String(localized: "You receive banners, sounds + badges.")
        case .provisional: String(localized: "Silent delivery to Notification Center.")
        case .denied: String(localized: "iOS is not showing banners right now. Re-enable them below.")
        case .notDetermined: String(localized: "iOS will ask you the first time.")
        case .unknown: String(localized: "iOS hasn't delivered anything yet.")
        }
    }

    /// v0.6.0.8 Issue #10 fix A — `true` for the two states where the
    /// top-level Settings call-out should render. `.unknown` is the
    /// pre-load placeholder and intentionally renders nothing so the
    /// card doesn't flicker in on every Settings open.
    var needsCallout: Bool {
        switch self {
        case .notDetermined, .denied: true
        case .authorized, .provisional, .unknown: false
        }
    }
}

// MARK: - Localization helper

enum NotificationEventLocalization {
    /// Server event-code → localized toggle title.
    ///
    /// **Why a dictionary, not a switch:** the same `cyclomatic_complexity`
    /// trade-off the project takes elsewhere (e.g. `MeasurementsStore`,
    /// `SourcePriorityDTO`) — the ~18-case mapping would trip the lint cap.
    /// The dictionary keeps it declarative, O(1), and single-source. Each
    /// value is a `LocalizedStringResource` so the literals stay extractable
    /// into `Localizable.xcstrings` and resolve per-locale at lookup.
    private static let titleByEvent: [String: LocalizedStringResource] = [
        "MEDICATION_REMINDER": "Medication reminder",
        "MEASUREMENT_ANOMALY": "Notable value",
        "COMPLIANCE_LOW": "Low compliance",
        "WITHINGS_SYNC_FAILED": "Withings sync failed",
        "SYSTEM_ALERT": "System notice",
        "PERSONAL_RECORD": "Personal record",
        "PERSONAL_RECORD_ACHIEVED": "Personal record",
        "INSIGHT_READY": "New insight",
        "DAILY_BRIEFING": "Daily briefing",
        "ACHIEVEMENT_UNLOCKED": "New achievement",
        "MOOD_REMINDER": "Mood reminder",
        "MEASUREMENT_REMINDER": "measurement.reminder.title",
        // v0153 INV-D L3 — newer server categories (coach + cycle). Without an
        // explicit entry these fell through to the old `default`, which
        // English-title-cased the raw SCREAMING_SNAKE code → "Coach Nudge",
        // "Cycle Period Confirm" leaked into the German build.
        "COACH_NUDGE": "Coach nudge",
        "CYCLE_PERIOD_CONFIRM": "Confirm period",
        "CYCLE_PERIOD_PREDICTED": "Period predicted",
        "CYCLE_FERTILE_WINDOW": "Fertile window",
        "CYCLE_OVULATION": "Ovulation",
        "REST_DAY": "Rest day",
        "VORSORGE_DUE": "Preventive care due",
        "SCREENING_DUE": "Preventive care due"
    ]

    /// Server event-code → localized toggle hint (subtitle). Optional: codes
    /// absent here render with no hint.
    ///
    /// **UI-Standard R1/R2 (U6) — hier steht genau noch ein Hint.** Die Liste
    /// trug 17 Unterzeilen; 13 davon buchstabierten nur ihren eigenen
    /// Zeilentitel nach („Neuer Insight" → „Wenn ein neuer Insight bereit
    /// ist.", „Eisprung" → „Rund um deinen geschätzten Eisprung-Tag.") und
    /// fallen damit unter die Abdeck-Probe aus R2 (Tautologie, Klasse A des
    /// Erklärtext-Audits). Zwei weitere sagten „Standardmäßig aus." — eine
    /// Voreinstellungs-Ansage, die R2 ausdrücklich verbietet, weil der
    /// Schalter daneben seinen Zustand selbst zeigt. Der Stimmungs-Hint nannte
    /// eine harte Uhrzeit („Abends 22:00"), die seit v0.10.0 W-Mood-B nur noch
    /// der Fallback-Default ist — die Uhrzeit stellt der Nutzer im DatePicker
    /// der Stimmungs-Karte ein (R7, Wahrheitspflicht); die Karte dort ist
    /// zugleich die Heimat der Aussage (R3).
    ///
    /// `DAILY_BRIEFING` bleibt, weil „Tägliches Briefing" weder Takt noch
    /// Tageszeit nennt — der Hint trägt Information, die der Titel nicht hat.
    private static let hintByEvent: [String: LocalizedStringResource] = [
        "DAILY_BRIEFING": "1 morning banner with your day."
    ]

    static func title(for eventType: String) -> String {
        // v0153 INV-D L3 hardening — an unknown server code must NOT be
        // English-title-cased in a non-English build. Fall back to a localized
        // generic label so a leak is impossible; the raw code is unsuitable as
        // UI copy.
        guard let resource = titleByEvent[eventType] else {
            return String(localized: "Notification")
        }
        return String(localized: resource)
    }

    static func hint(for eventType: String) -> String? {
        hintByEvent[eventType].map { String(localized: $0) }
    }
}

// MARK: - Test-push variants (B3 §3)

/// Three test-push shapes the user can fire from the Diagnose menu. Each
/// variant ships a different copy + `categoryIdentifier` so the user can
/// verify all the notification categories the app handles in production
/// (server payload-shapes). Per-variant `categoryIdentifier` also lets the
/// tap-routing path test deep-link destinations: even though the test push
/// has no `userInfo.deepLink`, the category prefix tells the
/// `UNUserNotificationCenterDelegate` which destination is intended.
enum TestPushVariant: String, CaseIterable, Identifiable, Hashable {
    case standard
    case moodReminder

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .moodReminder: String(localized: "Mood reminder")
        }
    }

    var symbol: String {
        switch self {
        case .standard: "bell.fill"
        case .moodReminder: "face.smiling"
        }
    }

    var title: String {
        switch self {
        case .standard: String(localized: "HealthLog — Test")
        case .moodReminder: String(localized: "How are you feeling right now?")
        }
    }

    var body: String {
        switch self {
        case .standard: String(localized: "If you see this, your notifications work.")
        case .moodReminder: String(localized: "Log your mood quickly — takes less than 30 seconds.")
        }
    }

    /// Mirrors the server-side `categoryIdentifier` values so taps on the
    /// test push route through the same code path as a real APN. Kept as
    /// untranslated raw strings to match what the server sends.
    var categoryIdentifier: String {
        switch self {
        case .standard: "TEST"
        case .moodReminder: "MOOD_REMINDER"
        }
    }
}

// MARK: - Section priority (UX ordering)

/// Maps server-emitted event-type strings to a UX-priority bucket so the
/// settings list reads in the order users care about — high-frequency
/// reminder → milestones → noise → system. Unknown types are bucketed
/// to the end so a new server eventType never crashes the layout.
enum NotificationEventPriority {
    /// Lower rank = higher priority (sorted ascending).
    static func rank(of eventType: String) -> Int {
        switch eventType {
        case "DAILY_BRIEFING": 10
        case "MOOD_REMINDER": 20
        case "MEDICATION_REMINDER": 30
        case "MEASUREMENT_REMINDER": 35
        case "ACHIEVEMENT_UNLOCKED", "PERSONAL_RECORD", "PERSONAL_RECORD_ACHIEVED": 40
        case "INSIGHT_READY": 50
        case "MEASUREMENT_ANOMALY": 60
        case "COMPLIANCE_LOW": 70
        case "WITHINGS_SYNC_FAILED": 80
        case "SYSTEM_ALERT": 90
        default: 1000
        }
    }
}

// swiftlint:enable file_length type_body_length
