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
    /// Glucose-context picker. `nil` represents "Ohne Kontext"
    /// (server keeps the row context-less). Only meaningful when
    /// `measurement.kind == .glucose`; ignored otherwise.
    @State private var glucoseContext: GlucoseContext?
    /// Baseline captured at prefill so a swipe-down only guards when the
    /// operator actually changed something.
    @State private var didPrefill = false
    @State private var initialScalar = ""
    @State private var initialSystolic = ""
    @State private var initialDiastolic = ""
    @State private var initialNote = ""
    @State private var initialRecordedAt = Date.now
    @State private var initialGlucoseContext: GlucoseContext?
    /// Whether the server takes a changed context (1.48.0, read at prefill).
    /// Against an older server the picker is not offered, so no choice is
    /// made that the save would drop.
    @State private var canEditGlucoseContext = false
    /// Future bound for the timestamp picker. A measurement cannot be
    /// recorded in the future (the create path's server contract mirrors
    /// `validateEntryInstant`); the edit sheet previously had an unbounded
    /// `DatePicker`. Held in state so the range doesn't churn per render, and
    /// never below the row's existing timestamp so a legacy future-dated row
    /// can't violate its own picker's range.
    @State private var recordedAtBound = Date.now
    /// Initial focus onto the primary value field.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case scalar, systolic, diastolic, note
    }

    /// Any field diverges from its prefilled baseline.
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
        HLSheetScaffold(
            "Edit",
            action: .save(isEnabled: isValid) { await save() },
            isDirty: isDirty
        ) {
            Form {
                // The same value input as the capture sheet, so editing a
                // reading looks like logging it.
                Section {
                    if case .bloodPressure = measurement.value {
                        HLAdaptiveStack { stacked in
                            HLNumericField(title: String(localized: "Systolic"), placeholder: "120", value: $systolicText)
                                .focused($focusedField, equals: .systolic)
                            if !stacked {
                                Text("/").foregroundStyle(HLText.secondary)
                            }
                            // The operator's BP unit (mmHg|kPa), not the
                            // canonical one; the fields carry the converted value.
                            HLNumericField(
                                title: String(localized: "Diastolic"),
                                placeholder: "80",
                                unit: units.bloodPressure.unitSuffix,
                                value: $diastolicText
                            )
                            .focused($focusedField, equals: .diastolic)
                        }
                        // The same per-component inline range hint as the
                        // create sheet, so a typo'd 1234 systolic cannot save.
                        if let err = systolicErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.systolic.error")
                        }
                        if let err = diastolicErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.diastolic.error")
                        }
                    } else {
                        HLNumericField(
                            title: measurement.kind.displayName,
                            placeholder: MeasureSheetView.placeholder(for: measurement.kind, units: units),
                            unit: MeasureEntryConversion.entrySuffix(kind: measurement.kind, units: units),
                            value: $scalarText
                        )
                        .focused($focusedField, equals: .scalar)
                        if let err = scalarErrorMessage {
                            inlineRangeError(err, identifier: "edit-measurement.scalar.error")
                        }
                    }
                } header: {
                    HLSectionHeader("Value")
                }
                .hlFormRowSurface()
                if measurement.kind == .glucose, canEditGlucoseContext {
                    Section {
                        Picker(selection: $glucoseContext) {
                            Text("No context").tag(GlucoseContext?.none)
                            ForEach(GlucoseContext.allCases) { context in
                                Text(context.displayResource).tag(GlucoseContext?.some(context))
                            }
                        } label: {
                            HLRowTitle("Context")
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("edit-measurement.glucose-context.picker")
                    } header: {
                        HLSectionHeader("Context")
                    }
                    .hlFormRowSurface()
                }
                Section {
                    DatePicker(
                        selection: $recordedAt,
                        in: ...recordedAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        HLRowTitle("measurement.form.recordedAt.label")
                    }
                } header: {
                    HLSectionHeader("measurement.form.recordedAt.section")
                }
                .hlFormRowSurface()
                Section {
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .focused($focusedField, equals: .note)
                } header: {
                    HLSectionHeader("Note")
                }
                .hlFormRowSurface()
                if let error {
                    Section {
                        HLFormErrorText(error.userFacingDescription)
                    }
                    .hlFormRowSurface()
                }
            }
            .hlPageMargins()
            // iOS 26+ soft scroll-edge so the Form blurs into
            // the sheet's Liquid Glass header instead of
            // clipping cleanly.
            .hlScrollEdgeSoft()
            .onAppear(perform: prefill)
            // Seed focus onto the primary value field once settled.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                if case .bloodPressure = measurement.value {
                    focusedField = .systolic
                } else {
                    focusedField = .scalar
                }
            }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        // Forward-convert the STORED canonical value into the unit the
        // operator types in, so the field and its suffix agree and the save path
        // can inverse-convert symmetrically. #191 QoL: at the precision the
        // row's label shows ("5,6 mmol/L" opens as "5,6"), never grouped, so
        // the number edited is the number read. An untouched field keeps the
        // stored value on save (below).
        switch measurement.value {
        case let .scalar(v):
            scalarText = MeasureEditPrefill.text(v, kind: measurement.kind, units: units)
        case let .bloodPressure(s, d):
            systolicText = MeasureEditPrefill.bloodPressureText(s, units: units)
            diastolicText = MeasureEditPrefill.bloodPressureText(d, units: units)
        }
        recordedAt = measurement.recordedAt
        recordedAtBound = max(.now, measurement.recordedAt)
        note = measurement.note ?? ""
        // Seed the glucose-context picker from the measurement's
        // existing context (nil for non-glucose rows).
        glucoseContext = measurement.glucoseContext
        canEditGlucoseContext = GlucoseContextEdit.isSupported()
        // Capture the prefilled baseline for the dirty check.
        initialScalar = scalarText
        initialSystolic = systolicText
        initialDiastolic = diastolicText
        initialNote = note
        initialRecordedAt = recordedAt
        initialGlucoseContext = glucoseContext
        didPrefill = true
    }

    /// The submit gate now runs the SAME `MeasureEntryValidation`
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
        HLFormErrorText(message)
            .hlText(.rowStatus, status: HLColor.statusBad)
            .accessibilityIdentifier(identifier)
    }

    private func save() async -> Bool {
        guard let container, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        error = nil

        // Inverse-convert the typed value FROM the operator's display
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
            guard isValid, let v = parsed(scalarText) else { return false }
            newValue = .scalar(
                scalarText == initialScalar
                    ? original
                    : MeasureEntryConversion.canonicalScalar(v, kind: measurement.kind, units: units)
            )
        case let .bloodPressure(originalSystolic, originalDiastolic):
            guard isValid, let s = parsed(systolicText), let d = parsed(diastolicText) else { return false }
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
        // can fan out a paired PATCH against both server rows (AC10). The
        // glucose context goes on the wire only when it changed and the
        // server takes it (1.48.0).
        let glucoseContextIntent: GlucoseContext? = measurement.kind == .glucose ? glucoseContext : nil
        let patch = MeasurementPatch.edit(
            measurement, to: newValue, at: recordedAt, notes: note.isEmpty ? nil : note, context: glucoseContext,
            serverTakesContext: canEditGlucoseContext
        )
        do {
            let updated = try await container.measurementsRepo.update(
                id: measurement.id,
                patch: patch,
                kind: measurement.kind,
                diastolicId: measurement.bloodPressureDiastolicId
            )
            // A server before 1.48.0 echoes the stored context; paint the
            // sheet's context back onto the row before handing it to the
            // list. From 1.48.0 the echo already matches (no-op).
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
            return true
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
        return false
    }

    private func parsed(_ s: String) -> Double? {
        LocaleDecimalParser.parse(s)
    }
}
