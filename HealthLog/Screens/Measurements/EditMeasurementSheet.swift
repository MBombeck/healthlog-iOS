import SwiftUI

/// Presented from `MeasurementListScreen` row swipe-action "Bearbeiten".
/// Renders a type-specific value field (single-line scalar or sys/dia pair),
/// a `DatePicker` for the timestamp, and a free-form note field. Save sends
/// `PATCH /api/measurements/[id]` via `MeasurementsStore.update`.
///
/// Per QA5: closes the 1/10 edit-coverage gap. Apple-reviewer's classic
/// "fix-a-typo on a freshly logged entry" test passes without ceremony —
/// swipe, pencil, type, save.
struct EditMeasurementSheet: View {
    let measurement: Measurement
    let onSaved: (Measurement) -> Void
    let onDismiss: () -> Void

    @Environment(\.appContainer) private var container
    /// Build 1 / item 1.3 — the operator's display-unit prefs (kg|lb / mmHg|kPa
    /// / mg/dL|mmol/L). The create path has threaded these since audit v0162 H-5;
    /// the edit path did not, so it prefilled + saved in CANONICAL units while
    /// every other surface rendered the operator's preferred ones. Now both ends
    /// of the edit round-trip speak the operator's unit.
    @Environment(\.unitPreferences) private var units

    @State private var scalarText: String = ""
    @State private var systolicText: String = ""
    @State private var diastolicText: String = ""
    @State private var recordedAt: Date = .now
    @State private var note: String = ""
    @State private var isSaving: Bool = false
    @State private var error: HLError?
    /// T-2 — glucose-context picker. `nil` represents "Ohne Kontext"
    /// (server keeps the row context-less). Only meaningful when
    /// `measurement.kind == .glucose`; ignored otherwise.
    @State private var glucoseContext: GlucoseContext?
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-1 — baseline captured at prefill so a swipe-down only guards when the
    /// operator actually changed something.
    @State private var didPrefill = false
    @State private var initialScalar = ""
    @State private var initialSystolic = ""
    @State private var initialDiastolic = ""
    @State private var initialNote = ""
    @State private var initialRecordedAt = Date.now
    @State private var initialGlucoseContext: GlucoseContext?
    /// Item 1.3 — future bound for the timestamp picker. A measurement cannot be
    /// recorded in the future (the create path's server contract mirrors
    /// `validateEntryInstant`); the edit sheet previously had an unbounded
    /// `DatePicker`. Held in state so the range doesn't churn per render, and
    /// never below the row's existing timestamp so a legacy future-dated row
    /// can't violate its own picker's range.
    @State private var recordedAtBound = Date.now
    /// FORM-2 (Audit v0162) — initial focus onto the primary value field.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case scalar, systolic, diastolic, note
    }

    /// FORM-1 — any field diverges from its prefilled baseline.
    private var isDirty: Bool {
        guard didPrefill else { return false }
        return scalarText != initialScalar
            || systolicText != initialSystolic
            || diastolicText != initialDiastolic
            || note != initialNote
            || recordedAt != initialRecordedAt
            || glucoseContext != initialGlucoseContext
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(measurement.kind.displayName) {
                    if case .bloodPressure = measurement.value {
                        HStack {
                            TextField("Systolic", text: $systolicText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .systolic)
                            Text("/")
                                .foregroundStyle(HLText.tertiary)
                            TextField("Diastolic", text: $diastolicText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .diastolic)
                            // Item 1.3 — the operator's BP unit (mmHg|kPa), not
                            // the canonical one. The fields now carry the
                            // converted value, so the suffix must match.
                            Text(verbatim: units.bloodPressure.unitSuffix)
                                .foregroundStyle(HLText.secondary)
                        }
                        // Item 1.3 — the same per-component inline range hint the
                        // create sheet has had since v0.5.5.2. The edit path had
                        // NO validation at all: a typo'd 1234 systolic saved.
                        if let err = systolicErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.systolic.error")
                        }
                        if let err = diastolicErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.diastolic.error")
                        }
                    } else {
                        HStack {
                            TextField("measurement.form.value.placeholder", text: $scalarText)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .scalar)
                            Text(verbatim: MeasureEntryConversion.entrySuffix(kind: measurement.kind, units: units))
                                .foregroundStyle(HLText.secondary)
                        }
                        if let err = scalarErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.scalar.error")
                        }
                    }
                }
                if measurement.kind == .glucose {
                    Section("Context") {
                        Picker("Context", selection: $glucoseContext) {
                            Text("No context").tag(GlucoseContext?.none)
                            ForEach(GlucoseContext.allCases) { context in
                                Text(context.displayResource).tag(GlucoseContext?.some(context))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("edit-measurement.glucose-context.picker")
                    }
                }
                Section("measurement.form.recordedAt.section") {
                    DatePicker(
                        "measurement.form.recordedAt.label",
                        selection: $recordedAt,
                        in: ...recordedAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .focused($focusedField, equals: .note)
                }
                if let error {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(HLColor.statusBad)
                    }
                }
            }
            // v0.5.x C-9 — iOS 26+ soft scroll-edge so the Form blurs into
            // the sheet's Liquid Glass header instead of clipping cleanly.
            // iOS 18-25: no-op (system stays flat-translucent).
            .hlScrollEdgeSoft()
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { showDiscardConfirm = true } else { onDismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !isValid)
                }
            }
            .onAppear(perform: prefill)
            // FORM-2 — seed focus onto the primary value field once settled.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                if case .bloodPressure = measurement.value {
                    focusedField = .systolic
                } else {
                    focusedField = .scalar
                }
            }
        }
        // FORM-1 — guard against a swipe-down discarding unsaved edits; keep the
        // existing in-flight save lock.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isSaving, isPresented: $showDiscardConfirm) {
            onDismiss()
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        // Item 1.3 — forward-convert the STORED canonical value into the unit the
        // operator types in, so the field and its suffix agree and the save path
        // can inverse-convert symmetrically. Identity for canonical-unit prefs.
        switch measurement.value {
        case let .scalar(v):
            scalarText = formatted(
                MeasureEntryConversion.displayScalar(v, kind: measurement.kind, units: units)
            )
        case let .bloodPressure(s, d):
            systolicText = formatted(units.convertBloodPressure(s))
            diastolicText = formatted(units.convertBloodPressure(d))
        }
        recordedAt = measurement.recordedAt
        recordedAtBound = max(.now, measurement.recordedAt)
        note = measurement.note ?? ""
        // T-2 — seed the glucose-context picker from the measurement's
        // existing context (nil for non-glucose rows).
        glucoseContext = measurement.glucoseContext
        // FORM-1 — capture the prefilled baseline for the dirty check.
        initialScalar = scalarText
        initialSystolic = systolicText
        initialDiastolic = diastolicText
        initialNote = note
        initialRecordedAt = recordedAt
        initialGlucoseContext = glucoseContext
        didPrefill = true
    }

    /// Item 1.3 — the submit gate now runs the SAME `MeasureEntryValidation`
    /// chain as the create sheet: parse → inverse-convert to canonical → check
    /// against the canonical band in `MeasurementRanges`. Previously the edit
    /// path only checked "is this a number", so a -500 kg weight or a 1234
    /// systolic saved without a word.
    private var isValid: Bool {
        switch measurement.value {
        case .scalar:
            MeasureEntryValidation.validateScalar(scalarText, kind: measurement.kind, units: units) == .ok
        case .bloodPressure:
            MeasureEntryValidation.validateBloodPressure(systolicText, component: .systolic, units: units) == .ok
                && MeasureEntryValidation.validateBloodPressure(diastolicText, component: .diastolic, units: units) == .ok
        }
    }

    private var scalarErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateScalar(scalarText, kind: measurement.kind, units: units),
            kind: measurement.kind,
            units: units
        )
    }

    private var systolicErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateBloodPressure(systolicText, component: .systolic, units: units),
            kind: .bloodPressure,
            component: .systolic,
            units: units
        )
    }

    private var diastolicErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateBloodPressure(diastolicText, component: .diastolic, units: units),
            kind: .bloodPressure,
            component: .diastolic,
            units: units
        )
    }

    /// Same inline affordance as `MeasureSheetView.inlineRangeError`.
    private func inlineRangeError(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.hlCaption)
            .foregroundStyle(HLColor.statusBad)
            .accessibilityIdentifier(identifier)
    }

    private func save() async {
        guard let container, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        error = nil

        // Item 1.3 — inverse-convert the typed value FROM the operator's display
        // unit TO canonical before it goes on the wire, exactly as the create
        // path has done since audit v0162 H-5
        // (`MeasureSheetView.swift:445-450`). Identity for canonical prefs; for a
        // lb / kPa / mmol-L operator this is what keeps an edit from rewriting
        // the record in the wrong unit space.
        //
        // An UNTOUCHED field keeps its ORIGINAL canonical value rather than
        // re-deriving it. The prefill renders at 2 decimal places, so for a
        // non-canonical unit the display→canonical round-trip is lossy by a
        // fraction (72.4 kg → "159,61" lb → 72.398 kg). Without this guard,
        // opening a row and pressing Speichern without typing would nudge the
        // stored value on every edit — a smaller version of exactly the defect
        // this item exists to close.
        let newValue: MeasurementValue
        switch measurement.value {
        case let .scalar(original):
            guard isValid, let v = parsed(scalarText) else { return }
            newValue = .scalar(
                scalarText == initialScalar
                    ? original
                    : MeasureEntryConversion.canonicalScalar(v, kind: measurement.kind, units: units)
            )
        case let .bloodPressure(originalSystolic, originalDiastolic):
            guard isValid, let s = parsed(systolicText), let d = parsed(diastolicText) else { return }
            newValue = .bloodPressure(
                systolic: systolicText == initialSystolic
                    ? originalSystolic
                    : units.canonicalBloodPressure(fromDisplayed: s),
                diastolic: diastolicText == initialDiastolic
                    ? originalDiastolic
                    : units.canonicalBloodPressure(fromDisplayed: d)
            )
        }
        // T-1 BP-pair patch: carry BOTH systolic + diastolic so the repo
        // can fan out a paired PATCH against both server rows. Pre-T-1
        // `MeasurementPatch.value` only carried systolic — diastolic was
        // silently dropped on every BP edit (AC10 finding).
        let diastolicIntent: Double? = if case let .bloodPressure(_, d) = newValue { d } else { nil }
        // T-2 — only set glucoseContext for glucose rows. The store is
        // already kind-guarded, but be explicit here so the wire shape
        // stays minimal for non-glucose kinds.
        let glucoseContextIntent: GlucoseContext? = measurement.kind == .glucose ? glucoseContext : nil
        let patch = MeasurementPatch(
            value: newValue.primaryComponent,
            measuredAt: recordedAt,
            notes: note.isEmpty ? nil : note,
            diastolic: diastolicIntent,
            glucoseContext: glucoseContextIntent
        )
        do {
            let updated = try await container.measurementsRepo.update(
                id: measurement.id,
                patch: patch,
                kind: measurement.kind,
                diastolicId: measurement.bloodPressureDiastolicId
            )
            // T-2 — server PATCH does not echo glucoseContext yet (SB-25),
            // so paint the user's intent back onto the row before handing
            // it back to the list. Once the server starts echoing the
            // field this branch becomes a no-op (saved.glucoseContext will
            // already match).
            let merged: Measurement = if measurement.kind == .glucose, updated.glucoseContext != glucoseContextIntent {
                Measurement(
                    id: updated.id,
                    kind: updated.kind,
                    recordedAt: updated.recordedAt,
                    value: updated.value,
                    note: updated.note,
                    source: updated.source,
                    externalUUID: updated.externalUUID,
                    bloodPressureDiastolicId: updated.bloodPressureDiastolicId,
                    glucoseContext: glucoseContextIntent
                )
            } else {
                updated
            }
            onSaved(merged)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    private func parsed(_ s: String) -> Double? {
        LocaleDecimalParser.parse(s)
    }

    private func formatted(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0 ... 2)).locale(.current))
    }
}
