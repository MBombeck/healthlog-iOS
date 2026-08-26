#if canImport(ActivityKit)
    import Foundation
    @testable import HealthLog
    import Testing

    /// **v0.8.4 WWIDGET-1** — pins the shared Live-Activity attribute /
    /// content-state shape so a drift in the static-vs-dynamic split (which
    /// would silently break the extension's decode of a running Activity)
    /// surfaces immediately. The type is compiled into both the app and the
    /// widget extension; this suite runs against the app-target copy.
    @Suite("MedicationActivityAttributes — shape + Codable")
    struct MedicationActivityAttributesTests {
        @Test("ContentState round-trips through Codable")
        func contentStateCodableRoundTrip() throws {
            let target = Date(timeIntervalSince1970: 1_800_000_000)
            let state = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: target
            )
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(
                MedicationActivityAttributes.ContentState.self,
                from: data
            )
            #expect(decoded.status == .pending)
            #expect(decoded.countdownTarget == target)
        }

        @Test("confirmed defaults to false and survives Codable")
        func confirmedFlagDefaultAndRoundTrip() throws {
            // Default — the controller's existing `ContentState(status:
            // countdownTarget:)` call-sites must stay source-compatible.
            let pending = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: Date(timeIntervalSince1970: 1_800_000_000)
            )
            #expect(pending.confirmed == false)

            // The in-place intent flips it true before the Activity ends; it
            // must round-trip so the running Activity decodes it in the
            // extension.
            var confirmed = pending
            confirmed.status = .taken
            confirmed.confirmed = true
            let data = try JSONEncoder().encode(confirmed)
            let decoded = try JSONDecoder().decode(
                MedicationActivityAttributes.ContentState.self,
                from: data
            )
            #expect(decoded.confirmed == true)
            #expect(decoded.status == .taken)
        }

        @Test("pendingConfirm defaults to false and round-trips with timestamp")
        func pendingConfirmDefaultAndRoundTrip() throws {
            let base = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: Date(timeIntervalSince1970: 1_800_000_000)
            )
            // Source-compat: existing call-sites never set it.
            #expect(base.pendingConfirm == false)
            #expect(base.pendingConfirmStartedAt == nil)

            var armed = base
            armed.pendingConfirm = true
            armed.pendingConfirmStartedAt = Date(timeIntervalSince1970: 1_800_000_123)
            let decoded = try JSONDecoder().decode(
                MedicationActivityAttributes.ContentState.self,
                from: JSONEncoder().encode(armed)
            )
            #expect(decoded.pendingConfirm == true)
            #expect(decoded.pendingConfirmStartedAt == armed.pendingConfirmStartedAt)
        }

        @Test("isOverdue defaults to false and round-trips (W-B183)")
        func isOverdueDefaultAndRoundTrip() throws {
            // Default — existing `ContentState(status:countdownTarget:)` call-sites
            // and any already-running activity decoded WITHOUT the key stay neutral.
            let base = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: Date(timeIntervalSince1970: 1_800_000_000)
            )
            #expect(base.isOverdue == false)

            // The app sets it from the server-gated composition; it must survive
            // Codable so the extension renders danger styling from the same truth.
            var overdue = base
            overdue.isOverdue = true
            let decoded = try JSONDecoder().decode(
                MedicationActivityAttributes.ContentState.self,
                from: JSONEncoder().encode(overdue)
            )
            #expect(decoded.isOverdue == true)
        }

        @Test("timeFormatRaw defaults to AUTO and round-trips (W-B187)")
        func timeFormatRawDefaultAndRoundTrip() throws {
            // Default — existing `ContentState(status:countdownTarget:)` call-sites
            // and any already-running activity decoded WITHOUT the key fall back
            // to "AUTO" (device-locale hour cycle), never a wrong clock.
            let base = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: Date(timeIntervalSince1970: 1_800_000_000)
            )
            #expect(base.timeFormatRaw == HLTimeFormat.auto.rawValue)

            // The app sets it from `HLTimeFormat.current()`; it must survive
            // Codable so the extension renders the dose time with the same
            // 12h/24h/auto preference the in-app card uses.
            var h24 = base
            h24.timeFormatRaw = HLTimeFormat.twentyFourHour.rawValue
            let decoded = try JSONDecoder().decode(
                MedicationActivityAttributes.ContentState.self,
                from: JSONEncoder().encode(h24)
            )
            #expect(decoded.timeFormatRaw == HLTimeFormat.twentyFourHour.rawValue)
        }

        @Test("Carried timeFormatRaw resolves to the app's HLTimeFormat clock (W-B187)")
        func timeFormatRawMatchesAppPreference() {
            // The widget formats the static dose time via
            // `(HLTimeFormat(rawValue: state.timeFormatRaw) ?? .auto).formatTime(_:)`
            // (LiveActivityStyle `dueAt`/`takenAt`). Pin that the resolved clock
            // string equals the app-side `HLTimeFormat` for the same pref, so the
            // Live-Activity dose time can never diverge from the card / home widget.
            let dose = Date(timeIntervalSince1970: 1_800_000_000)
            for pref in [HLTimeFormat.auto, .twelveHour, .twentyFourHour] {
                let state = MedicationActivityAttributes.ContentState(
                    status: .pending,
                    countdownTarget: dose,
                    timeFormatRaw: pref.rawValue
                )
                let resolved = HLTimeFormat(rawValue: state.timeFormatRaw) ?? .auto
                #expect(resolved == pref)
                #expect(resolved.formatTime(dose) == pref.formatTime(dose))
            }
        }

        @Test("Status raw values are stable wire strings")
        func statusRawValues() {
            #expect(MedicationActivityAttributes.ContentState.Status.pending.rawValue == "pending")
            #expect(MedicationActivityAttributes.ContentState.Status.taken.rawValue == "taken")
            #expect(MedicationActivityAttributes.ContentState.Status.snoozed.rawValue == "snoozed")
        }

        @Test("Attributes carry the intake-scheduled-for key for the intent")
        func attributesCarryIntakeKey() {
            let fire = Date(timeIntervalSince1970: 1_800_000_000)
            let attributes = MedicationActivityAttributes(
                medicationId: "med-1",
                medicationName: "Vitamin D",
                doseText: "1000 IE",
                scheduledFireDate: fire,
                intakeScheduledFor: fire
            )
            // The intake key the MarkMedicationTakenIntent records against
            // must equal the shown due time in normal operation.
            #expect(attributes.intakeScheduledFor == attributes.scheduledFireDate)
            #expect(attributes.medicationId == "med-1")
        }
    }

    /// **v0.10 Walkthrough-2 LA2** — the two-step anti-accidental tap-confirm
    /// state machine. The pure `MarkDoseFromLiveActivityIntent.step(for:)`
    /// decision is exercised without a live ActivityKit Activity (the in-place
    /// `activity.update`/`.end` calls are operator device-validated).
    @Suite("MarkDoseFromLiveActivityIntent — two-step confirm state machine")
    struct LiveActivityConfirmStepTests {
        private let target = Date(timeIntervalSince1970: 1_800_000_000)
        private let now = Date(timeIntervalSince1970: 1_800_000_500)

        private func pending() -> MedicationActivityAttributes.ContentState {
            MedicationActivityAttributes.ContentState(status: .pending, countdownTarget: target)
        }

        @Test("First tap on a pending dose ARMS (no intake recorded)")
        func firstTapArms() {
            let step = MarkDoseFromLiveActivityIntent.step(for: pending(), now: now)
            guard case let .arm(armed) = step else {
                Issue.record("expected .arm, got \(step)")
                return
            }
            #expect(armed.pendingConfirm == true)
            #expect(armed.pendingConfirmStartedAt == now)
            // Crucially still NOT confirmed — one tap never records.
            #expect(armed.confirmed == false)
            #expect(armed.status == .pending)
        }

        @Test("Second tap on an armed dose COMMITS (records + confirms)")
        func secondTapCommits() {
            // Arm first.
            guard case let .arm(armed) = MarkDoseFromLiveActivityIntent.step(for: pending(), now: now) else {
                Issue.record("arm step failed")
                return
            }
            // Tap again on the armed state.
            let step = MarkDoseFromLiveActivityIntent.step(for: armed, now: now)
            guard case let .commit(confirming) = step else {
                Issue.record("expected .commit, got \(step)")
                return
            }
            #expect(confirming.confirmed == true)
            #expect(confirming.status == .taken)
            // Pending flag cleared on commit.
            #expect(confirming.pendingConfirm == false)
            #expect(confirming.pendingConfirmStartedAt == nil)
        }

        @Test("Already-confirmed dose is a no-op (idempotent stray tap)")
        func confirmedIsNoOp() {
            var confirmed = pending()
            confirmed.status = .taken
            confirmed.confirmed = true
            #expect(MarkDoseFromLiveActivityIntent.step(for: confirmed, now: now) == .none)
        }

        @Test("Arm → commit is a full round-trip (one accidental tap never records)")
        func fullRoundTrip() {
            // The contract: from a fresh pending state, a SINGLE tap can never
            // reach .commit — it must pass through .arm first.
            let first = MarkDoseFromLiveActivityIntent.step(for: pending(), now: now)
            if case .commit = first {
                Issue.record("a single tap reached .commit — accidental-tap guard broken")
            }
        }
    }
#endif
