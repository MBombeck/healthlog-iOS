import SwiftUI

/// **W-REMINDERS (#23 v1.18.1) — create / edit a Vorsorge reminder.**
///
/// A form sheet building a `MeasurementReminderCreate` body for
/// `POST /api/measurement-reminders`, or (edit mode) a
/// `MeasurementReminderUpdate` PATCH for `/api/measurement-reminders/{id}`.
/// The mode is inferred from `editing != nil`; one form, two verbs.
///
/// **Build 6.4 — the full editor.** Beyond the original label + type + interval
/// + hour, the form now captures:
/// - a **cadence type** switch (rolling `intervalDays` vs an RFC-5545 `rrule`),
///   with common RRULE presets and a custom-rule escape hatch;
/// - an optional **anchor date** (the schedule's start instant), which can be
///   set or explicitly cleared on edit;
/// - a free-text **location** hint; and
/// - a per-reminder **enabled** toggle.
///
/// Editing the cadence — including SWITCHING between interval and RRULE and
/// nulling the anchor — is now active end-to-end: the PATCH is built by the
/// pure `MeasurementReminderRow.editingPatch(…)` with exact omitted/null/set
/// semantics (`RecordPatchField`), verified against the server's #62 recompute
/// fix. The server owns `nextDueAt`; the client never sets or predicts due dates.
///
/// `onCreate` / `onUpdate` return `true` on success (the parent re-lists +
/// dismisses).
struct MeasurementReminderCreateSheet: View {
    /// Returns `true` when the create succeeded. Used in create mode.
    let onCreate: (MeasurementReminderCreate) async -> Bool
    /// The reminder being edited, or `nil` for create mode.
    let editing: MeasurementReminderRow?
    /// Returns `true` when the PATCH succeeded. Used in edit mode.
    let onUpdate: (String, MeasurementReminderUpdate) async -> Bool

    init(
        editing: MeasurementReminderRow? = nil,
        onCreate: @escaping (MeasurementReminderCreate) async -> Bool,
        onUpdate: @escaping (String, MeasurementReminderUpdate) async -> Bool = { _, _ in false }
    ) {
        self.editing = editing
        self.onCreate = onCreate
        self.onUpdate = onUpdate
    }

    @Environment(\.dismiss) private var dismiss
    @State var label = ""
    /// `nil` = free-text reminder (no auto-resolve type).
    @State var selectedType: String?
    @State var cadenceMode: ReminderCadenceMode = .interval
    @State var intervalDays = 30
    @State var rrulePreset: RRulePreset = .yearly
    @State var customRrule = ""
    @State var useAnchorDate = false
    @State var anchorDate = Date.now
    @State var notifyHour = 9
    @State var location = ""
    @State var enabled = true
    @State private var submitting = false
    @State private var prefilled = false
    /// Captured once after prefill so the discard guard compares against the
    /// real starting state (create-defaults or the edited reminder's values).
    @State private var initialSnapshot: FormSnapshot?
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 (Audit v0162) — initial focus onto the label field. Internal (not
    /// private) so the section builders in the `+Sections` extension can bind it.
    @FocusState var labelFocused: Bool

    var isEditing: Bool {
        editing != nil
    }

    /// The RFC-5545 rule the RRULE path currently represents: a preset's wire
    /// string, or the trimmed custom rule. Independent of `cadenceMode` (so it
    /// can't recurse through ``resolvedCadence``); it is only consumed on the
    /// RRULE path.
    var effectiveRrule: String {
        if let wire = rrulePreset.wire { return wire }
        return customRrule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A cadence is only submittable on the RRULE path when the rule carries a
    /// `FREQ=` token (the server's minimum RRULE guard) and fits the 512-char
    /// bound. The interval path is always valid.
    var rruleIsValid: Bool {
        let rule = effectiveRrule
        return rule.count <= 512 && rule.range(of: "FREQ=", options: .caseInsensitive) != nil
    }

    /// The typed cadence the form resolves to right now.
    var resolvedCadence: ReminderCadence {
        switch cadenceMode {
        case .interval: .interval(intervalDays)
        case .rrule: .rrule(effectiveRrule)
        }
    }

    var canSubmit: Bool {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !submitting else { return false }
        switch cadenceMode {
        case .interval: return true
        case .rrule: return rruleIsValid
        }
    }

    /// The live form state, compared against ``initialSnapshot`` for the
    /// discard guard. Anchor date is only significant when the toggle is on.
    var currentSnapshot: FormSnapshot {
        FormSnapshot(
            label: label,
            selectedType: selectedType,
            cadenceMode: cadenceMode,
            intervalDays: intervalDays,
            rrulePreset: rrulePreset,
            customRrule: customRrule,
            useAnchorDate: useAnchorDate,
            anchorDate: useAnchorDate ? anchorDate : nil,
            notifyHour: notifyHour,
            location: location,
            enabled: enabled
        )
    }

    var isDirty: Bool {
        guard let initialSnapshot else { return false }
        return initialSnapshot != currentSnapshot
    }

    var body: some View {
        NavigationStack {
            Form {
                labelSection
                typeSection
                cadenceSection
                anchorSection
                notifyHourSection
                locationSection
                if isEditing { enabledSection }
            }
            .navigationTitle(isEditing ? Text("reminders.edit.title") : Text("reminders.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: prefillIfNeeded)
            // FORM-2 — seed focus onto the label field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                labelFocused = true
            }
        }
        // FORM-1 — guard against a swipe-down discarding unsaved edits; keep the
        // existing in-flight submit lock.
        .hlDiscardGuard(isDirty: isDirty, isSaving: submitting, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if isDirty { showDiscardConfirm = true } else { dismiss() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if submitting {
                ProgressView()
            } else {
                Button("reminders.create.save") { Task { await submit() } }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("MeasurementReminderCreateSheet.save")
            }
        }
    }

    /// Hydrates the form from the edited reminder once. Render-only fields
    /// (`nextDueAt`/`lastSatisfiedAt`) are never copied — only the editable
    /// cadence inputs. A reminder on an `rrule` schedule seeds the RRULE path
    /// (mapping the rule onto a known preset, or the custom escape hatch); an
    /// interval reminder seeds the interval path.
    private func prefillIfNeeded() {
        guard !prefilled else { return }
        defer {
            prefilled = true
            initialSnapshot = currentSnapshot
        }
        guard let row = editing else { return }
        label = row.label
        selectedType = row.measurementType
        if row.isRRuleScheduled, let rule = row.rrule {
            cadenceMode = .rrule
            rrulePreset = RRulePreset(wire: rule)
            if rrulePreset == .custom { customRrule = rule }
        } else {
            cadenceMode = .interval
            if let interval = row.intervalDays { intervalDays = interval }
        }
        if let anchor = row.anchorDate {
            useAnchorDate = true
            anchorDate = anchor
        }
        if let hour = row.notifyHour { notifyHour = hour }
        location = row.location ?? ""
        enabled = row.enabled
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = useAnchorDate ? anchorDate : nil
        if let row = editing {
            let patch = MeasurementReminderRow.editingPatch(
                for: row,
                label: trimmedLabel,
                measurementType: selectedType,
                cadence: resolvedCadence,
                anchorDate: anchor,
                notifyHour: notifyHour,
                location: location,
                enabled: enabled
            )
            if await onUpdate(row.id, patch) { dismiss() }
        } else {
            let body = MeasurementReminderCreate(
                label: trimmedLabel,
                measurementType: selectedType,
                cadence: resolvedCadence,
                anchorDate: anchor,
                notifyHour: notifyHour,
                location: location,
                enabled: enabled
            )
            if await onCreate(body) { dismiss() }
        }
    }
}

// MARK: - Cadence mode

/// Which cadence family the form is editing. Distinct from ``ReminderCadence``
/// (which carries the value) — this is the segmented-control selection.
enum ReminderCadenceMode: String, CaseIterable, Identifiable {
    case interval
    case rrule

    var id: String {
        rawValue
    }
}

// MARK: - RRULE presets

/// Common preventive-care recurrences, each mapping to a canonical RFC-5545
/// rule the server's recurrence engine understands. `custom` is the escape
/// hatch for a hand-entered rule.
enum RRulePreset: String, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case semiannual
    case yearly
    case custom

    var id: String {
        rawValue
    }

    /// The canonical wire rule, or `nil` for `custom` (the user types their own).
    var wire: String? {
        switch self {
        case .weekly: "FREQ=WEEKLY"
        case .biweekly: "FREQ=WEEKLY;INTERVAL=2"
        case .monthly: "FREQ=MONTHLY"
        case .quarterly: "FREQ=MONTHLY;INTERVAL=3"
        case .semiannual: "FREQ=MONTHLY;INTERVAL=6"
        case .yearly: "FREQ=YEARLY"
        case .custom: nil
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .weekly: "reminders.create.rrule.weekly"
        case .biweekly: "reminders.create.rrule.biweekly"
        case .monthly: "reminders.create.rrule.monthly"
        case .quarterly: "reminders.create.rrule.quarterly"
        case .semiannual: "reminders.create.rrule.semiannual"
        case .yearly: "reminders.create.rrule.yearly"
        case .custom: "reminders.create.rrule.custom"
        }
    }

    /// Reverse-map a stored rule onto a known preset (normalising case + spaces),
    /// falling back to `.custom` so any hand-written or future rule still round-
    /// trips through the editor without being silently rewritten.
    init(wire rule: String) {
        let normalised = rule.uppercased().replacingOccurrences(of: " ", with: "")
        for preset in RRulePreset.allCases where preset.wire?.uppercased() == normalised {
            self = preset
            return
        }
        self = .custom
    }
}

// MARK: - Discard snapshot

/// A value snapshot of every editable field, captured after prefill so the
/// discard guard can tell a pristine sheet from an edited one without a wall of
/// per-field comparisons.
struct FormSnapshot: Equatable {
    let label: String
    let selectedType: String?
    let cadenceMode: ReminderCadenceMode
    let intervalDays: Int
    let rrulePreset: RRulePreset
    let customRrule: String
    let useAnchorDate: Bool
    let anchorDate: Date?
    let notifyHour: Int
    let location: String
    let enabled: Bool
}
