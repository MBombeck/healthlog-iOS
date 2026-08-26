// swiftlint:disable file_length type_body_length
//
// File-length budget — the pure `Snapshot` model, its test seam and the
// consumer cards share one file because they are one cohesive
// self-diagnose target per `docs/architecture.md`. 08-15 moved the
// registration audit, the banner categories and the pending identifiers
// out to `SettingsSupportDiagnosticsScreen`, so the overrun is smaller
// than it was; the directive stays because the `Snapshot` builder below
// is what carries the length, not the view.
import SwiftUI
#if canImport(UserNotifications) && canImport(UIKit)
    import UIKit
    import UserNotifications

    /// v0.5.5 W-MED — self-diagnosis surface for the notification
    /// pipeline. Reachable for every user under Settings →
    /// Notifications → "Advanced diagnostics" so somebody whose banner
    /// never arrives can find out where it stops.
    ///
    /// Shows:
    /// - UNUserNotificationCenter authorization status, with the recovery
    ///   action that matches it.
    /// - The medication numbers the in-app surfaces consume.
    /// - How many local reminders iOS currently holds.
    /// - "Trigger test banner" gated behind a 3-second long-press.
    ///
    /// **08-15 — what this screen deliberately no longer shows.** The APNs
    /// registration audit, the registered banner categories with their raw
    /// action identifiers, and the individual pending-request identifiers are
    /// support instruments: they mean something next to a server log and
    /// nothing to somebody asking why their banner is late. They moved to
    /// ``SettingsSupportDiagnosticsScreen`` behind a deliberate, view-local
    /// ``SupportDiagnosticsSession``. Nothing was deleted and nothing was
    /// duplicated — the row at the bottom of this page is the way there.
    ///
    /// **U10 — no raw literals.** Every user-visible string on this screen
    /// is an English source key with a `de` + `en` unit in
    /// `Localizable.xcstrings`; `NotificationDiagnosticsLiteralGuardTests`
    /// pins that. The labels name what the reader can check, not the
    /// internal role that produced the number (the old "Operator sieht" /
    /// "Synth-Slots" wording described our development, not their data).
    /// Genuinely technical terms (APNs, token prefix) stay technical —
    /// a diagnostics screen must not hide behind friendly words.
    struct NotificationDiagnosticsScreen: View {
        @Environment(MedicationsStore.self) private var medicationsStore
        @Environment(\.appContainer) private var container
        @State private var snapshot: Snapshot = .placeholder
        @State private var refreshing: Bool = false
        @State private var testSentAt: Date?
        @State private var testError: String?
        @State private var medsLastRefreshOutcome: MedsRefreshOutcome = .notYetAttempted
        @State private var refreshTick: Int = 0

        var body: some View {
            HLSettingsPage(title: "Advanced diagnostics") {
                authorizationCard
                medsDataCard
                pendingRequestsCard
                testNotificationCard
                supportDiagnosticsCard
            }
            .task { await refresh() }
            .refreshable {
                await refresh()
                refreshTick &+= 1
            }
            // POLISH-SWEEP: success-tick confirms pull-to-refresh round-trip.
            .sensoryFeedback(.success, trigger: refreshTick)
        }

        // MARK: - Cards

        private var authorizationCard: some View {
            HLSettingsCard(
                icon: "bell.badge.fill",
                title: "Permission",
                footer: authorizationFooter
            ) {
                LabeledRow(
                    title: "Status",
                    value: snapshot.authorizationLabel,
                    accessibilityIdentifier: "meds.diagnostics.authStatus"
                )
                if let action = authorizationAction {
                    Divider().opacity(0.5)
                    Button {
                        Task { await runAuthorizationAction(action) }
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                            .font(.hlSubhead)
                    }
                    .accessibilityIdentifier("notif.diagnostics.authorize")
                }
            }
        }

        /// **UI-Standard R3/R4 (U6).** Von drei Fußnoten bleibt eine.
        ///
        /// - `denied` und `authorized` waren Wegweiser („… in den
        ///   iOS-Einstellungen"). Für `denied` steht der Absprung als Knopf in
        ///   derselben Karte (`authorizationAction == .deepLinkSettings`) —
        ///   R4: dann gehört dorthin nichts mehr. Für `authorized` wiederholte
        ///   der erste Satz die Status-Zeile darüber, und der Fokus-/
        ///   Zusammenfassungs-Hinweis steht bereits im Footer der
        ///   Diagnose-Karte auf „Benachrichtigungen", von der aus diese Seite
        ///   geöffnet wird (R3, eine Aussage, ein Ort).
        /// - `notDetermined` behält nur die Grenze, die der Knopf nicht zeigt:
        ///   iOS fragt genau einmal pro Installation. Die Bedien-Nacherzählung
        ///   („Drücke auf …") ist gefallen.
        private var authorizationFooter: LocalizedStringKey? {
            switch snapshot.authorizationStatus {
            case .notDetermined:
                "iOS asks for this permission only once per install."
            default:
                nil
            }
        }

        /// Tri-state CTA matching the auth-status. `nil` while iOS reports
        /// `authorized` / `provisional` (no recovery action needed) and
        /// while the snapshot has not loaded yet (avoids a flash of "open
        /// settings" on first paint).
        private var authorizationAction: AuthorizationAction? {
            switch snapshot.authorizationStatus {
            case .notDetermined: .requestPrompt
            case .denied: .deepLinkSettings
            default: nil
            }
        }

        @MainActor
        private func runAuthorizationAction(_ action: AuthorizationAction) async {
            switch action {
            case .requestPrompt:
                guard let notif = container?.notifications else { return }
                _ = await notif.requestAuthorization()
                await refresh()
            case .deepLinkSettings:
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                await UIApplication.shared.open(url)
            }
        }

        /// **08-15 — the way to the detail this screen no longer carries.**
        ///
        /// The APNs registration audit, the registered banner categories and
        /// the pending-request identifiers used to sit inline here, three taps
        /// from the Settings hub for every consumer. They now live behind a
        /// deliberate, view-local support session in
        /// ``SettingsSupportDiagnosticsScreen`` — which is why this row is a
        /// plain push and not a shortcut: the gate is the destination's, and it
        /// starts locked on every mount.
        private var supportDiagnosticsCard: some View {
            HLSettingsCard(
                icon: "lifepreserver",
                title: "settings.support.title",
                footer: "settings.support.entry_footer"
            ) {
                HLSettingsActionRow(title: "settings.support.nav_row", presents: .push) {
                    SettingsSupportDiagnosticsScreen(topic: .notifications)
                }
                .accessibilityIdentifier("notif.supportDiagnostics.entry")
            }
        }

        /// W-MED2 — the medication numbers the in-app surfaces consume,
        /// so a reader can answer "does today's dose list look right?"
        /// without Xcode: how many medications are active, how many
        /// doses the server has already created for today, how many the
        /// app filled in from the schedule, the total that ends up on
        /// screen, and when the data was last fetched.
        ///
        /// **U10 wording.** "Synth-Slots" and "Operator sieht" named
        /// our implementation (synthesized placeholders) and our own
        /// role. Both now say what the reader sees: the app added them,
        /// and this is the total the app shows.
        private var medsDataCard: some View {
            HLSettingsCard(
                icon: "pills.fill",
                title: "Medication data",
                footer: "Doses the server has already created for today. The app fills in the remaining ones from your schedule."
            ) {
                LabeledRow(
                    title: "Active medications",
                    value: "\(activeMedsCount)",
                    accessibilityIdentifier: "meds.diagnostics.activeMedsCount"
                )
                Divider().opacity(0.5)
                LabeledRow(
                    title: "From the server (today)",
                    value: "\(serverIntakeCount)",
                    accessibilityIdentifier: "meds.diagnostics.serverIntakeCount"
                )
                Divider().opacity(0.5)
                LabeledRow(
                    title: "Added by the app",
                    value: "\(synthIntakeCount)",
                    accessibilityIdentifier: "meds.diagnostics.synthIntakeCount"
                )
                Divider().opacity(0.5)
                LabeledRow(
                    title: "Shown in the app",
                    value: "\(derivedIntakeCount)",
                    accessibilityIdentifier: "meds.diagnostics.derivedIntakeCount"
                )
                Divider().opacity(0.5)
                LabeledRow(
                    title: "Last loaded",
                    value: medsLastRefreshLabel,
                    accessibilityIdentifier: "meds.diagnostics.lastMedsRefresh"
                )
            }
        }

        /// **08-15 — the count stays, the identifiers moved.**
        ///
        /// "iOS has twelve reminders queued" is the answer a user waiting for a
        /// banner needs, and it is safe to read anywhere. The individual request
        /// identifiers are not: they carry the internal scheduling scheme and,
        /// through it, what was scheduled. They are now redacted support detail
        /// behind ``SupportDiagnosticsSession``.
        private var pendingRequestsCard: some View {
            HLSettingsCard(
                icon: "calendar",
                title: "Scheduled notifications",
                // R18 (U6) — war ein deutsches Quell-Literal ohne Katalog-Eintrag
                // (PROJECT_GUIDE.md: keine hardcodierten UI-Strings); jetzt englischer
                // Quellschlüssel mit de/en im Katalog.
                footer: "Local reminders iOS has already scheduled. Server pushes do not appear here."
            ) {
                LabeledRow(
                    title: "Count",
                    value: "\(snapshot.pendingCount)",
                    accessibilityIdentifier: "meds.diagnostics.pendingCount"
                )
            }
        }

        private var testNotificationCard: some View {
            // UI-Standard R3 (U6) — die Lokalitäts-Zusicherung („bleibt lokal,
            // keine Server-Daten") steht am Footer der Diagnose-Karte auf
            // „Benachrichtigungen", von der aus diese Seite geöffnet wird.
            // Hier bleibt nur die Bedienbesonderheit, die es sonst nirgends
            // gibt: der Knopf reagiert auf langes Drücken, nicht auf Tippen.
            HLSettingsCard(
                icon: "paperplane.fill",
                title: "Test banner",
                footer: "Long-press (3 sec), then the banner fires in 5 seconds."
            ) {
                Button {
                    // Long-press is the trigger — plain tap is a no-op.
                } label: {
                    Label("Trigger test banner", systemImage: "paperplane.fill")
                        .font(.hlSubhead)
                }
                .hlGlassButtonStyle()
                .accessibilityIdentifier("meds.diagnostics.testTrigger")
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 3.0)
                        .onEnded { _ in
                            Task { await sendTestNotification() }
                        }
                )
                if let sentAt = testSentAt {
                    Text(
                        String(
                            format: String(localized: "Sent at %@ — should appear shortly."),
                            sentAt.formatted(.dateTime.hour().minute().second())
                        )
                    )
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .accessibilityIdentifier("meds.diagnostics.testSentAt")
                }
                if let err = testError {
                    Text(err)
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .accessibilityIdentifier("meds.diagnostics.testError")
                }
            }
        }

        // MARK: - Meds-data derived values

        private var activeMedsCount: Int {
            medicationsStore.medications.filter(\.active).count
        }

        private var serverIntakeCount: Int {
            medicationsStore.todayIntakes.filter {
                !$0.id.hasPrefix(MedicationIntake.synthesizedPlaceholderPrefix)
            }.count
        }

        private var synthIntakeCount: Int {
            // The derived array minus what the server actually emitted —
            // mirrors what the dashboard tile / Erfassen sheet show
            // beyond the server's authoritative payload.
            medicationsStore.derivedTodayIntakes.filter(\.isSynthesizedPlaceholder).count
        }

        private var derivedIntakeCount: Int {
            medicationsStore.derivedTodayIntakes.count
        }

        private var medsLastRefreshLabel: String {
            switch medsLastRefreshOutcome {
            case .notYetAttempted:
                String(localized: "Not loaded yet")
            case let .success(at):
                String(
                    format: String(localized: "Loaded at %@"),
                    at.formatted(.dateTime.hour().minute().second())
                )
            case let .failure(message):
                String(localized: "notifications.diagnostics.error \(message)")
            }
        }

        // MARK: - Snapshot building

        private func refresh() async {
            guard !refreshing else { return }
            refreshing = true
            defer { refreshing = false }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let categories = await center.notificationCategories()
            let pending = await center.pendingNotificationRequests()
            snapshot = Snapshot.build(
                settings: settings,
                categories: categories,
                pending: pending
            )
            // Pull a fresh medications/today-intakes snapshot in parallel so
            // the operator's diagnostic numbers reflect the current server
            // state (not just whatever last landed in the SWR cache).
            await refreshMedsData()
        }

        private func refreshMedsData() async {
            await medicationsStore.load()
            if let err = medicationsStore.error {
                let raw = String(describing: err)
                let trimmed = raw.count > 80 ? String(raw.prefix(77)) + "…" : raw
                medsLastRefreshOutcome = .failure(message: trimmed)
                HLLog.notifications.error(
                    "Meds diagnostic refresh failed: \(LogSanitizer.redact(raw), privacy: .public)"
                )
            } else {
                medsLastRefreshOutcome = .success(at: .now)
            }
        }

        private func sendTestNotification() async {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "notifications.diagnostics.title")
            content.body = String(localized: "Test banner — if you see this, notifications work.")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let id = "meds.diagnostics.test.\(UUID().uuidString)"
            let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            do {
                try await UNUserNotificationCenter.current().add(req)
                testSentAt = .now
                testError = nil
                // Locally generated random test-banner id; the UUID portion is
                // sanitizer-redacted by HLLogger anyway — no user data.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.info("Diagnostics test banner queued id=\(id, privacy: .public)")
                await refresh()
            } catch {
                testError = String(localized: "notifications.diagnostics.scheduleError \(error.localizedDescription)")
                HLLog.notifications.error(
                    "Diagnostics test banner failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }

    // MARK: - W-MED2 meds-refresh outcome

    extension NotificationDiagnosticsScreen {
        /// Outcome of the last `MedicationsStore.load()` triggered from
        /// the diagnostics screen — surfaced verbatim to the operator
        /// so they can correlate "Server-Einnahmen 0 + Synth-Slots 2"
        /// with a recent network success vs. a silent error swallow.
        enum MedsRefreshOutcome: Equatable {
            case notYetAttempted
            case success(at: Date)
            case failure(message: String)
        }

        /// v0.6.0.8 — tri-state CTA for the permission card. Drives
        /// the iOS authorization recovery flow per Issue #10 fix A:
        /// `.notDetermined` invites the System prompt; `.denied`
        /// deep-links to iOS Settings; `.authorized` / `.provisional`
        /// render no button (`authorizationAction` returns `nil`).
        enum AuthorizationAction {
            case requestPrompt
            case deepLinkSettings

            var title: LocalizedStringKey {
                switch self {
                case .requestPrompt: "Enable notifications"
                case .deepLinkSettings: "Open in Settings"
                }
            }

            var symbol: String {
                switch self {
                case .requestPrompt: "bell.fill"
                case .deepLinkSettings: "arrow.up.right.square"
                }
            }
        }
    }

    // MARK: - Row primitive

    /// **U10 — `title` is a `LocalizedStringKey`, not a `String`.**
    ///
    /// It used to be a `String`, and `Text(_ content: some StringProtocol)`
    /// is the *non*-localizing initializer: every row label on this screen
    /// rendered its source literal verbatim, in whatever language it
    /// happened to be written in. That is why a German build showed
    /// "Active medications" and an English one "Letzter Versuch" — the
    /// catalog entries existed for some of them and were never consulted.
    /// `value` stays a `String`: it carries numbers, timestamps and
    /// already-localized text, never a catalog key.
    private struct LabeledRow: View {
        let title: LocalizedStringKey
        let value: String
        let accessibilityIdentifier: String

        var body: some View {
            HStack {
                Text(title)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.secondary)
                Spacer(minLength: HLSpace.sm)
                Text(value)
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLText.primary)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    // MARK: - Pure snapshot

    extension NotificationDiagnosticsScreen {
        /// Pure-data view-model. Built off the UN Center's three async
        /// queries. The build function is non-isolated so tests can
        /// construct snapshots without spinning up a UN center mock.
        struct Snapshot: Equatable {
            struct CategoryRow: Equatable {
                let identifier: String
                let actionsLabel: String
            }

            struct PendingPreview: Equatable {
                let identifier: String
                let fireLabel: String
            }

            let authorizationLabel: String
            /// v0.6.0.8 — raw `UNAuthorizationStatus` so the screen can
            /// pick the right re-trigger CTA without re-deriving from
            /// the localised label.
            let authorizationStatus: UNAuthorizationStatus?
            let categories: [CategoryRow]
            let pendingCount: Int
            let nextPendingPreviews: [PendingPreview]

            static let placeholder = Snapshot(
                authorizationLabel: String(localized: "notifications.diagnostics.loading"),
                authorizationStatus: nil,
                categories: [],
                pendingCount: 0,
                nextPendingPreviews: []
            )

            static func build(
                settings: UNNotificationSettings,
                categories: Set<UNNotificationCategory>,
                pending: [UNNotificationRequest],
                now: Date = .now,
                maxPreviews: Int = 5
            ) -> Snapshot {
                let sortedCategories = categories
                    .sorted { $0.identifier < $1.identifier }
                    .map { CategoryRow(identifier: $0.identifier, actionsLabel: actionList($0)) }
                let sortedPending = pending
                    .compactMap { req -> (UNNotificationRequest, Date)? in
                        guard let fireDate = nextFireDate(for: req, now: now) else { return nil }
                        return (req, fireDate)
                    }
                    .sorted { $0.1 < $1.1 }
                    .prefix(maxPreviews)
                    .map { req, fireDate in
                        PendingPreview(
                            identifier: req.identifier,
                            fireLabel: previewLabel(for: fireDate, now: now)
                        )
                    }
                return Snapshot(
                    authorizationLabel: label(for: settings.authorizationStatus),
                    authorizationStatus: settings.authorizationStatus,
                    categories: sortedCategories,
                    pendingCount: pending.count,
                    nextPendingPreviews: Array(sortedPending)
                )
            }

            /// Pure snapshot builder seam for tests — exposes category +
            /// pending shaping without requiring a real
            /// `UNNotificationSettings` instance.
            static func buildForTesting(
                authorizationLabel: String,
                categories: [(identifier: String, actionIdentifiers: [String])],
                pendingCount: Int,
                previews: [(identifier: String, fireLabel: String)],
                authorizationStatus: UNAuthorizationStatus? = nil
            ) -> Snapshot {
                let categoryRows = categories
                    .sorted { $0.identifier < $1.identifier }
                    .map { entry in
                        CategoryRow(
                            identifier: entry.identifier,
                            actionsLabel: entry.actionIdentifiers.isEmpty
                                ? String(localized: "No actions")
                                : entry.actionIdentifiers.joined(separator: ", ")
                        )
                    }
                let previewRows = previews.map {
                    PendingPreview(identifier: $0.identifier, fireLabel: $0.fireLabel)
                }
                return Snapshot(
                    authorizationLabel: authorizationLabel,
                    authorizationStatus: authorizationStatus,
                    categories: categoryRows,
                    pendingCount: pendingCount,
                    nextPendingPreviews: previewRows
                )
            }

            private static func label(for status: UNAuthorizationStatus) -> String {
                switch status {
                case .authorized: String(localized: "notifications.diagnostics.allowed")
                case .provisional: String(localized: "Provisionally allowed")
                case .ephemeral: String(localized: "App Clip — ephemeral")
                case .denied: String(localized: "notifications.diagnostics.denied")
                case .notDetermined: String(localized: "Not decided yet")
                @unknown default: String(localized: "Unknown")
                }
            }

            private static func actionList(_ category: UNNotificationCategory) -> String {
                let ids = category.actions.map(\.identifier)
                if ids.isEmpty {
                    return String(localized: "No actions")
                }
                return ids.joined(separator: ", ")
            }

            private static func nextFireDate(for request: UNNotificationRequest, now: Date) -> Date? {
                if let interval = request.trigger as? UNTimeIntervalNotificationTrigger {
                    return interval.nextTriggerDate() ?? now.addingTimeInterval(interval.timeInterval)
                }
                if let calendar = request.trigger as? UNCalendarNotificationTrigger {
                    return calendar.nextTriggerDate()
                }
                return nil
            }

            private static func previewLabel(for fireDate: Date, now: Date) -> String {
                let formatter = RelativeDateTimeFormatter()
                formatter.dateTimeStyle = .named
                return formatter.localizedString(for: fireDate, relativeTo: now)
            }
        }
    }
#endif
// swiftlint:enable file_length type_body_length
