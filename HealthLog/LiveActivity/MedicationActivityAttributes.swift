#if canImport(ActivityKit)
    import ActivityKit
    import Foundation

    /// **Medication-reminder Live Activity attributes.**
    ///
    /// Drives the Lock-Screen banner + Dynamic Island for a single due
    /// medication dose. The type is intentionally a small, self-contained
    /// value (plain `String` / `Date` / a tiny status enum) carrying **no**
    /// app-only domain types — it is compiled into *both* the app target
    /// (which owns the `Activity.request/update/end` lifecycle via
    /// ``MedicationLiveActivityController``) and the widget extension
    /// target (which renders it). Keeping the closure minimal is what lets
    /// the same file be a shared source-membership without dragging the
    /// repository stack across the target boundary.
    ///
    /// **Static vs. dynamic split:**
    /// - ``MedicationActivityAttributes`` (static) — fixed for the life of
    ///   the Activity: which medication, its dose text, the scheduled fire
    ///   time, and the `intakeScheduledFor` instant the
    ///   `MarkMedicationTakenIntent` records against.
    /// - ``ContentState`` (dynamic) — what changes as the user acts: the
    ///   ``Status`` (pending / taken / snoozed) and the countdown target
    ///   the Lock-Screen / Dynamic-Island view feeds to
    ///   `Text(timerInterval:)`.
    ///
    /// **Why `intakeScheduledFor` is carried explicitly:** the
    /// "Genommen" button fires `MarkMedicationTakenIntent`, whose
    /// `perform()` calls `MedicationsRepository.recordFromReminder(
    /// medicationId:scheduledFor:status:)`. The bulk-intake endpoint keys
    /// the idempotent insert-or-return on `(medicationId, scheduledFor)`,
    /// so the Live Activity must hand the *scheduled* instant — not "now"
    /// — to the intent so the recorded row aligns with the dose the banner
    /// represents (and so a tap from the banner and a tap from the in-app
    /// card collapse onto the same server row).
    struct MedicationActivityAttributes: ActivityAttributes {
        /// Server medication id — the stable key the
        /// `MarkMedicationTakenIntent` records against. Also used as the
        /// Activity's logical identity so the controller can find + update
        /// the running Activity for a given medication.
        let medicationId: String

        /// Display name, e.g. "Vitamin D". Server-supplied medication
        /// record content, not a UI string, so it is passed through
        /// verbatim.
        let medicationName: String

        /// Dose text, e.g. "1000 IE" / "500 mg". Server-supplied free text.
        let doseText: String

        /// The scheduled fire instant this dose is due. Rendered as the
        /// human "fällig um HH:mm" sub-line.
        let scheduledFireDate: Date

        /// The instant the `MarkMedicationTakenIntent` records the intake
        /// against (`recordFromReminder(scheduledFor:)`). Equal to
        /// ``scheduledFireDate`` in normal operation; carried separately so
        /// a future server contract can decouple "due time shown" from
        /// "intake row key" without a schema change here.
        let intakeScheduledFor: Date

        struct ContentState: Codable, Hashable {
            /// Lifecycle status of the dose as the user acts on it.
            enum Status: String, Codable, Hashable {
                case pending
                case taken
                case snoozed
            }

            var status: Status

            /// The instant the countdown counts down to (the scheduled
            /// fire time while pending). Fed to `Text(timerInterval:)` so
            /// the OS renders a self-updating "in 12 Min" / "vor 4 Min"
            /// label without the process having to tick a timer.
            var countdownTarget: Date

            /// Set `true` the instant the
            /// in-place "Genommen" Live-Activity intent records the dose,
            /// *before* the Activity ends. Drives the green-check success
            /// transition the user sees on the Lock Screen WITHOUT the app
            /// foregrounding.
            ///
            /// Distinct from `status == .taken` (which the app-side reconcile
            /// loop in `AppContainer+LiveActivity` also reaches once the app is
            /// alive): `confirmed` is the *interactive ack* the extension flips
            /// synchronously from `MarkDoseFromLiveActivityIntent.perform()` so
            /// the check animates immediately on tap. Defaults to `false` so the
            /// controller's existing `ContentState(status:countdownTarget:)`
            /// call-sites stay source-compatible.
            var confirmed: Bool = false

            /// **v0.10 Walkthrough-2 LA2 — anti-accidental two-step tap.** Set
            /// `true` by the FIRST tap on "Genommen" (the intent flips it via
            /// `activity.update`), which relabels the button to "Erneut tippen
            /// zum Bestätigen". The SECOND tap (button now in this pending state)
            /// actually records the intake + sets `confirmed = true` + ends the
            /// Activity. One accidental tap therefore never records a dose.
            ///
            /// `pendingConfirmStartedAt` carries the instant the pending state
            /// began; the intent compares it on the second tap so a fresh
            /// (re-shown) Activity can't inherit a stale pending flag, and the
            /// view can drive a `Text(timerInterval:)` visual hint toward the
            /// auto-revert horizon. Defaults keep existing call-sites compatible.
            var pendingConfirm: Bool = false

            /// The instant the `pendingConfirm` window opened (first tap). `nil`
            /// while not pending. Used to bound the confirm window + drive the
            /// countdown-to-revert hint.
            var pendingConfirmStartedAt: Date?

            /// The server-gated overdue
            /// truth, computed in the APP process and carried into the widget.
            ///
            /// The widget extension is a SEPARATE process that cannot reach the
            /// server, so it previously derived "overdue" itself as
            /// `Date.now > countdownTarget`. That bypassed the server's
            /// future-due gate (`nextDueAt` / `nextDueOverdue`) and painted a
            /// rolling/weekly med red the instant its (phantom) local window
            /// passed — the Trulicity family of bugs (taken weekly, next dose
            /// weeks away, must NOT read "stark überfällig").
            ///
            /// The app computes this with the SAME composition the in-app card
            /// uses (`MedicationWindowStatus.reduce(...) ?? serverOverdueFallback(...)`,
            /// including the future-server-due suppression). `countdownTarget`
            /// still drives the timer text + range; only the DANGER styling
            /// reads this flag. Defaults to `false` so the controller's existing
            /// `ContentState(status:countdownTarget:)` call-sites and any
            /// already-running activity decoded without this key stay neutral.
            var isOverdue: Bool = false

            /// The user's resolved
            /// `HLTimeFormat` raw value ("AUTO" / "H12" / "H24"), computed in the
            /// APP process and carried into the widget so the Live-Activity dose
            /// time ("fällig um HH:mm" / "Genommen um HH:mm") honours the SAME
            /// server `User.timeFormat` preference the in-app card and the
            /// home-screen NextDose widget already render through `HLTimeFormat`.
            ///
            /// The widget extension is a SEPARATE process whose
            /// `UserDefaults.standard` does NOT carry the app's
            /// `HLTimeFormat.defaultsKey` mirror (it would always read `.auto`),
            /// so — exactly like the App-Group `WidgetSnapshot.timeFormatRaw` for
            /// the home-screen widget — the resolved value must travel in the
            /// ContentState. The static dose-time strings format through
            /// `HLTimeFormat(rawValue: timeFormatRaw)`; only those static clocks
            /// switch — `Text(timerInterval:)` stays an OS-driven live timer.
            ///
            /// Defaults to `HLTimeFormat.auto.rawValue` ("AUTO") so the
            /// controller's existing `ContentState(status:countdownTarget:)`
            /// call-sites and any already-running activity decoded without this
            /// key fall back to the device locale's own hour cycle.
            var timeFormatRaw: String = "AUTO"

            /// The wire keys. Spelled out so the hand-written decoder below and
            /// the synthesized encoder agree on one list, and so the golden
            /// fixture (`HealthLogTests/Fixtures/LiveActivity/`) has a single
            /// place to be compared against.
            enum CodingKeys: String, CodingKey {
                case status
                case countdownTarget
                case confirmed
                case pendingConfirm
                case pendingConfirmStartedAt
                case isOverdue
                case timeFormatRaw
            }
        }
    }

    extension MedicationActivityAttributes.ContentState {
        /// **#188 (2) — a content state the server sends must always decode.**
        ///
        /// ActivityKit decodes the `content-state` of every remote `update` and
        /// `end` push with this initializer. The synthesized decoder required
        /// every key, defaults included, so the `"content-state": {}` an `end`
        /// carried failed with `keyNotFound "status"` and the end was dropped:
        /// the countdown kept running after the dose was taken on the web.
        ///
        /// Every key is optional now. A missing or unknown `status` reads as
        /// `.pending` (the state the server cannot have ended from anything
        /// else), a missing `countdownTarget` as the moment of decoding, and the
        /// flags keep their declared defaults. Lives in an extension so the
        /// memberwise initializer the controller and the intents call stays.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawStatus = try? container.decodeIfPresent(String.self, forKey: .status)
            status = rawStatus.flatMap(Status.init(rawValue:)) ?? .pending
            countdownTarget = try container.decodeIfPresent(Date.self, forKey: .countdownTarget) ?? Date()
            confirmed = try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
            pendingConfirm = try container.decodeIfPresent(Bool.self, forKey: .pendingConfirm) ?? false
            pendingConfirmStartedAt = try container.decodeIfPresent(Date.self, forKey: .pendingConfirmStartedAt)
            isOverdue = try container.decodeIfPresent(Bool.self, forKey: .isOverdue) ?? false
            timeFormatRaw = try container.decodeIfPresent(String.self, forKey: .timeFormatRaw) ?? "AUTO"
        }

        /// **#188 (6) — what the countdown corner shows at `now`.**
        enum CountdownPresentation: Equatable {
            /// Nothing: the dose is snoozed, taken or confirmed.
            case hidden
            /// Counting down to the due time.
            case countdown(ClosedRange<Date>)
            /// The due time has passed; counts up from it
            /// (`Text(target, style: .relative)`).
            case overdueSince(Date)
        }

        /// Before the due time a forward timer; from the due time on the time
        /// since then, which keeps counting on its own. The clamped range the
        /// views used before showed the seconds since the last render once the
        /// target had passed. While snoozed nothing counts, on every surface.
        func countdownPresentation(now: Date) -> CountdownPresentation {
            guard status == .pending, !confirmed else { return .hidden }
            guard countdownTarget > now else { return .overdueSince(countdownTarget) }
            return .countdown(now ... countdownTarget)
        }
    }
#endif
