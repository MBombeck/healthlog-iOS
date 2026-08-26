import SwiftUI

struct MeasureSheetView: View {
    @Environment(MeasurementsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Audit v0162 H-5 — the user's display-unit prefs (kg|lb / mmHg|kPa /
    /// mg/dL|mmol/L). Threaded in so the entry path can inverse-convert the
    /// typed value FROM the preferred unit TO canonical before storing +
    /// range-validating, mirroring the display path's forward conversion.
    /// `.standard` (canonical identity) when there's no store handle.
    @Environment(\.unitPreferences) private var units
    /// v0.15 W-FRONTDOORS — optional type-prefill. When set (e.g. the Home
    /// Vorsorge tile's "jetzt messen" for a due BP reminder), the picker seeds
    /// to this kind ONCE on appear, overriding the last-used-kind restore so the
    /// operator lands directly on the metric the reminder targets. `nil` keeps
    /// the existing last-used-kind behaviour for the central Erfassen path.
    var initialKind: MetricKind?
    /// H1 (v0.11 W26) — last-used metric kind, persisted across sheet opens
    /// so the morning weigh-in stops re-resetting to Blutdruck. `@AppStorage`
    /// (UI-pref only, PROJECT_GUIDE.md-allowed). Seeds `kind` in `.task` before the
    /// keyboard settles; updated on every successful save.
    @AppStorage("measure.lastKind") private var lastKindRaw: String = MetricKind.bloodPressure.rawValue
    /// H1 — recent distinct kinds (MRU, newest-first, comma-joined raw values,
    /// capped at `Self.recentKindLimit`) feeding the one-tap chip row. Also a
    /// UI-pref. Updated alongside `lastKindRaw` on save.
    @AppStorage("measure.recentKinds") private var recentKindsRaw: String = ""
    @State private var kind: MetricKind = .bloodPressure
    /// True once `.task` has seeded `kind` from `lastKindRaw`, so the seeding
    /// runs exactly once and a later user pick isn't clobbered.
    @State private var didSeedKind = false
    @State private var systolic: String = ""
    @State private var diastolic: String = ""
    @State private var scalar: String = ""
    /// v0158 — pain NRS picker selection (0–10 integer). Separate from `scalar`
    /// because pain is captured via a wheel picker, not the decimal text field.
    @State private var painScore: Int = 0
    @State private var note: String = ""
    /// **Build 1 / item 1.4b — backdating.** The capture path hard-coded
    /// `recordedAt: .now` (`MeasurementsStore+QuickCapture.swift`), so the only
    /// way to log yesterday's weigh-in was save-then-edit. Web has carried the
    /// field plus an explicit hint since `measurement-form.tsx:539-560`.
    @State private var recordedAt: Date = .now
    /// Future bound for the timestamp picker (web: `max={getDefaultMeasuredAt…}`,
    /// mirroring the server's `validateEntryInstant`). Held in state so the range
    /// doesn't churn per render; refreshed when the sheet settles.
    @State private var recordedAtBound: Date = .now
    /// T-2 — glucose-context picker selection. Only shown when
    /// `kind == .glucose`. `nil` = "Ohne Kontext" (server keeps the row
    /// context-less).
    @State private var glucoseContext: GlucoseContext?
    /// v0.5.5.1 haptic migration: save-outcome triggers for declarative
    /// `.sensoryFeedback`. Replaces the legacy
    /// `UINotificationFeedbackGenerator().notificationOccurred(.success/.error)`
    /// pair so SwiftUI manages prepare-and-fire + Reduce-Motion semantics.
    @State private var saveOk: Int = 0
    @State private var saveErr: Int = 0
    /// v0.5.5.2 — visible save-error surface. Before this fix, a failed
    /// `store.capture(...)` only triggered the error-haptic — there was
    /// no banner, no inline text, no toast (PROJECT_GUIDE.md anti-pattern:
    /// "silent error swallowing"). We now mirror the store error into
    /// local state, render an `ErrorBanner` overlay at the top, and
    /// auto-clear it on the next user input so the operator never gets
    /// stuck reading a stale failure after they typed past it.
    @State private var saveError: HLError?
    @FocusState private var primaryFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // H1 (v0.11 W26) — recent-kinds chip row: one-tap switch to
                    // the last few kinds the user logged, so the common case
                    // (Gewicht / Blutdruck / Glukose) is a single tap instead of
                    // a 22-item menu dive. Hidden until there's recent history.
                    if !recentKinds.isEmpty {
                        recentKindChips
                            .listRowInsets(EdgeInsets(top: HLSpace.xs, leading: HLSpace.md, bottom: HLSpace.xs, trailing: HLSpace.md))
                    }
                    Picker("Metric", selection: $kind) {
                        ForEach(supportedKinds) { k in
                            Label(k.displayName, systemImage: symbol(for: k)).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(String(localized: "Value")) {
                    if kind == .bloodPressure {
                        HStack {
                            HLNumericField(title: String(localized: "Systolic"), placeholder: "120", value: $systolic)
                                .focused($primaryFocused)
                            Text("/").foregroundStyle(HLText.secondary)
                            // H-5 — surface the BP unit suffix (mmHg|kPa) on the
                            // trailing leg so the operator knows which unit both
                            // fields are in.
                            HLNumericField(
                                title: String(localized: "Diastolic"),
                                placeholder: "80",
                                unit: units.bloodPressure.unitSuffix,
                                value: $diastolic
                            )
                        }
                        // v0.5.5.2 — per-component inline range hint.
                        // Without this the operator can submit a 30/200
                        // pair (or a typo'd 1234 systolic) and only find
                        // out via the server 422.
                        if let err = systolicErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.systolic.error")
                        }
                        if let err = diastolicErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.diastolic.error")
                        }
                    } else if kind == .painNRS {
                        // v0158 — bespoke 0–10 integer NRS picker. The server
                        // accepts any 0–10 float, so the integer constraint is a
                        // client responsibility: a wheel picker can only yield a
                        // valid 0…10 integer (no decimal text field for pain).
                        painNRSPicker
                    } else {
                        // H-5 — show the entry-unit suffix so the operator knows
                        // which unit they're typing (kg|lb, mg/dL|mmol/L, …).
                        HLNumericField(
                            title: kind.displayName,
                            placeholder: placeholder,
                            unit: MeasureEntryConversion.entrySuffix(kind: kind, units: units),
                            value: $scalar
                        )
                        .focused($primaryFocused)
                        // v0.5.5.2 — inline range hint when the scalar
                        // sits outside the per-kind sane range. Submit
                        // stays disabled (`canSave`) until the operator
                        // either fixes the value or clears the field.
                        if let err = scalarErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.scalar.error")
                        }
                    }
                }

                if kind == .glucose {
                    Section("Context") {
                        Picker("Context", selection: $glucoseContext) {
                            Text("No context").tag(GlucoseContext?.none)
                            ForEach(GlucoseContext.allCases) { context in
                                Text(context.displayResource).tag(GlucoseContext?.some(context))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("measure-sheet.glucose-context.picker")
                    }
                }

                // Item 1.4b — backdating. Bounded to "not in the future"; the
                // footer is the web's own hint copy, which exists because users
                // kept missing that the field was adjustable at all.
                Section {
                    DatePicker(
                        "measurement.form.recordedAt.label",
                        selection: $recordedAt,
                        in: ...recordedAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("measure-sheet.recordedAt.picker")
                } header: {
                    Text("measurement.form.recordedAt.section")
                } footer: {
                    Text("measurement.form.backdateHint")
                }

                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(2 ... 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HLColor.background)
            // v0.5.x C-9 — iOS 26+ soft scroll-edge so the Form blurs into
            // the sheet's Liquid Glass header instead of clipping cleanly.
            // iOS 18-25: no-op (system stays flat-translucent).
            .hlScrollEdgeSoft()
            .navigationTitle("Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
        // A6 §5 — fire focus AFTER the sheet has settled so the keyboard
        // doesn't fight the .presentationDetents transition. Combined with
        // the caller-side .hlSheetPresentation(.form) (full-height detent),
        // this kills the "half-open → pause → full-with-keyboard" glitch
        // reported as user-report #4.
        .task {
            // H1 — seed the picker from the last-used kind exactly once, before
            // the keyboard settles. A later user pick is preserved (`didSeedKind`).
            if !didSeedKind {
                // v0.15 W-FRONTDOORS — an explicit prefill (Vorsorge "jetzt messen")
                // wins over the last-used-kind restore; otherwise restore the MRU.
                if let initialKind, supportedKinds.contains(initialKind) {
                    kind = initialKind
                } else if let restored = MetricKind(rawValue: lastKindRaw), supportedKinds.contains(restored) {
                    kind = restored
                }
                didSeedKind = true
            }
            // Item 1.4b — refresh the "not in the future" bound to the moment the
            // sheet actually opened.
            recordedAtBound = .now
            try? await Task.sleep(for: HLSheet.focusDelay)
            primaryFocused = true
        }
        // v0.5.5.1 haptic migration: declarative success/error feedback on
        // save outcome.
        .sensoryFeedback(.success, trigger: saveOk)
        .sensoryFeedback(.error, trigger: saveErr)
        // v0.5.5.2 — surface the save error visually. Before this the
        // operator only got a haptic; the banner makes the failure
        // legible so they know what went wrong + can retry.
        .overlay(alignment: .top) {
            // A2-M4 — give the save-error banner an explicit way forward.
            // Previously the only retry was the still-live Save button, which a
            // user might not realise is tappable; every other ErrorBanner call
            // site passes a retry closure, so align this one.
            ErrorBanner(error: saveError, retry: { Task { await save() } })
                .accessibilityIdentifier("measure-sheet.save-error.banner")
                .hlAnimation(.default, value: saveError)
        }
        // Clear the banner the moment the operator changes any input —
        // they've moved past the failure, the message is stale.
        .onChange(of: systolic) { _, _ in saveError = nil }
        .onChange(of: diastolic) { _, _ in saveError = nil }
        .onChange(of: scalar) { _, _ in saveError = nil }
        .onChange(of: painScore) { _, _ in saveError = nil }
        .onChange(of: note) { _, _ in saveError = nil }
        .onChange(of: kind) { _, _ in saveError = nil }
    }

    /// **Every kind here MUST have a `toCreateDTOs()` arm.** This list is the
    /// picker's promise; `MeasurementDTO.toCreateDTOs()` is what the promise is
    /// worth. A kind offered here but absent there falls into that switch's
    /// `default: []`, the repository's `guard !dtos.isEmpty` throws, and the
    /// operator gets an error banner on a value they were invited to enter.
    ///
    /// **Build 1 / item 1.4 removed nine such kinds** — `.bmi`, `.walkingSpeed`,
    /// `.walkingAsymmetry`, `.walkingStepLength`, `.walkingDoubleSupport`,
    /// `.audioExposureEnvironment`, `.audioExposureHeadphone`, `.steps`,
    /// `.sleep`. All nine are HealthKit-derived and reach the server over the
    /// batch observer path (`HealthKitBatchEntryDTO`), which has no manual-entry
    /// counterpart. (They were NOT silently dropped before this change — the
    /// repository guard threw and the sheet stayed open — but offering them at
    /// all was a promise the app could not keep.)
    ///
    /// FOLLOW-UP (owner: iOS, Build 3 — Custom Metrics / measurements depth):
    /// `.bmi` is the one removal with a plausible manual path, since BMI is
    /// derivable from weight + a stored height. That needs a height source
    /// decision first (the same one blocking `.waistToHeight`), so it is a
    /// feature to design rather than a wire arm to bolt on here.
    ///
    /// Order matches the dashboard's canonical layout family: vitals first
    /// (BP / Pulse / Resting-HR / HRV / Respiratory / Glucose / SpO2 / Temp /
    /// Pain), body composition next (Weight / BodyFat / BodyWater / BoneMass),
    /// manual clinical signals and VO2 max last.
    private var supportedKinds: [MetricKind] {
        [
            .bloodPressure, .pulse, .restingHeartRate, .hrv, .respiratoryRate, .glucose, .spo2, .bodyTemperature,
            // v0158 — pain NRS is a manual symptom signal; sits with the vitals.
            .painNRS,
            .weight, .bodyFat, .bodyWater, .boneMass,
            // v0158 — waist circumference + grip strength are manual clinical
            // signals (HK-less / HK-deferred). Waist-to-height is render-only and
            // intentionally absent here (no manual-entry path).
            .waistCircumference, .gripStrength,
            .vo2Max
        ]
    }

    // MARK: - H1 recent-kinds chips (v0.11 W26)

    /// Max distinct kinds kept in the recent-kinds MRU + shown as chips.
    private static let recentKindLimit = 5

    /// Parsed recent-kinds MRU (newest-first), filtered to kinds the picker
    /// actually supports so a stale raw value can't surface a dead chip.
    private var recentKinds: [MetricKind] {
        MeasureRecentKinds.parse(recentKindsRaw, allowed: supportedKinds)
    }

    /// One-tap chip row over the recent kinds. The active kind reads selected
    /// (filled), the rest are hairline outlines — mirrors the `TagChip`
    /// monochrome vocabulary.
    private var recentKindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HLSpace.sm) {
                ForEach(recentKinds) { k in
                    Button {
                        kind = k
                    } label: {
                        HStack(spacing: HLSpace.xs) {
                            Image(systemName: symbol(for: k))
                                .imageScale(.small)
                            Text(k.displayName)
                                .font(.hlSubhead)
                        }
                        .padding(.horizontal, HLSpace.md)
                        .padding(.vertical, HLSpace.chip)
                        .foregroundStyle(k == kind ? HLColor.background : HLText.primary)
                        .background(
                            Capsule()
                                .fill(k == kind ? AnyShapeStyle(HLText.primary) : AnyShapeStyle(Color.clear))
                        )
                        .overlay(
                            Capsule()
                                .stroke(k == kind ? Color.clear : HLText.tertiary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("measure-sheet.recent-chip.\(k.rawValue)")
                    .accessibilityAddTraits(k == kind ? .isSelected : [])
                }
            }
        }
    }

    /// Persist `picked` as last-used + move it to the front of the recent MRU,
    /// de-duping and capping at `recentKindLimit`.
    private func persistRecentKind(_ picked: MetricKind) {
        lastKindRaw = picked.rawValue
        recentKindsRaw = MeasureRecentKinds.push(
            picked,
            into: recentKindsRaw,
            allowed: supportedKinds,
            limit: Self.recentKindLimit
        )
    }

    /// v0158 — 0–10 integer NRS pain picker. A wheel picker structurally
    /// constrains the selection to a valid 0…10 integer, satisfying the
    /// client-side integer requirement the server does not enforce.
    private var painNRSPicker: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Picker(String(localized: "Pain level"), selection: $painScore) {
                ForEach(PainScoreInput.range, id: \.self) { score in
                    Text("\(score)").tag(score)
                }
            }
            .pickerStyle(.wheel)
            .accessibilityIdentifier("measure-sheet.pain-nrs.picker")
            Text(String(localized: "0 = no pain · 10 = worst imaginable"))
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
    }

    private func symbol(for k: MetricKind) -> String {
        // Single source of truth — pull from the descriptor catalog rather
        // than maintain a parallel switch that drifts whenever a new kind
        // joins the registry. The catalog already supplies SF Symbols for
        // every kind (locked in by `MetricKindDescriptorRegistryTests`).
        k.descriptor.sfSymbol
    }

    /// V052-R3 U-H2 — example placeholder per kind. The descriptor catalog
    /// doesn't carry a textfield placeholder yet (it surfaces `unitLabel`,
    /// `title`, empty-state copy), and the values here are user-friendly
    /// "typical" examples rather than canonical defaults. Kept inline so a
    /// reader can scan the picker contents without leaving the sheet file.
    private var placeholder: String {
        switch kind {
        case .weight: "72,4"
        case .glucose: "92"
        case .pulse: "62"
        case .bodyFat: "22,5"
        case .bodyTemperature: "36,8"
        case .spo2: "98"
        case .bodyWater: "42"
        case .boneMass: "3,2"
        case .restingHeartRate: "55"
        case .hrv: "45"
        case .vo2Max: "42,5"
        // v0158 — manual clinical decimal fields (pain uses a picker, not this).
        case .gripStrength: "38,0"
        case .waistCircumference: "84,0"
        default: "0"
        }
    }

    /// **v0.5.5.2 — submit-gate now honors per-kind sane-range validation.**
    /// Before this the operator could type `-500` weight or `99999`
    /// glucose, hit Speichern, and only learn the value was out-of-range
    /// from the server 422. We now refuse the submit client-side and keep
    /// the inline error hint visible until the value lands inside the
    /// range OR the field is cleared.
    private var canSave: Bool {
        if kind == .bloodPressure {
            // H-5 — validate in canonical mmHg space (inverse-converting the
            // typed mmHg|kPa value first) so a kPa entry isn't wrongly blocked.
            let s = MeasureEntryValidation.validateBloodPressure(systolic, component: .systolic, units: units)
            let d = MeasureEntryValidation.validateBloodPressure(diastolic, component: .diastolic, units: units)
            return s == .ok && d == .ok
        }
        // v0158 — pain NRS is captured via the wheel picker; any picked value is
        // a valid 0…10 integer, so the submit gate is always open (0 = no pain).
        if kind == .painNRS {
            return PainScoreInput.isValid(painScore)
        }
        // H-5 — validate against the canonical range in canonical unit space
        // (inverse-converting the typed value first), so e.g. 5.5 mmol/L glucose
        // is checked as ~99 mg/dL and is no longer range-blocked.
        return MeasureEntryValidation.validateScalar(scalar, kind: kind, units: units) == .ok
    }

    /// Inline error copy for the systolic field. `nil` when the field is
    /// empty (we don't shout before the operator types) OR when the value
    /// is valid. Anything else (.notANumber / .belowMinimum / .aboveMaximum)
    /// surfaces a localised "ausserhalb des Bereichs (50 – 260 mmHg)" hint.
    private var systolicErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateBloodPressure(systolic, component: .systolic, units: units),
            kind: .bloodPressure,
            component: .systolic,
            units: units
        )
    }

    private var diastolicErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateBloodPressure(diastolic, component: .diastolic, units: units),
            kind: .bloodPressure,
            component: .diastolic,
            units: units
        )
    }

    /// Inline error copy for the single-value scalar field. Surfaces the
    /// per-kind range hint (e.g. "Wert ausserhalb des sinnvollen Bereichs
    /// (0,1 – 600 kg)") when the operator types something past the bound.
    private var scalarErrorMessage: String? {
        MeasureEntryValidation.localizedError(
            for: MeasureEntryValidation.validateScalar(scalar, kind: kind, units: units),
            kind: kind,
            units: units
        )
    }

    /// Standard inline error label. Centralised so the systolic / diastolic
    /// / scalar paths share the same affordance — red `.hlCaption` text
    /// below the field, with an accessibility identifier the UI tests can
    /// pin against.
    private func inlineRangeError(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.hlCaption)
            .foregroundStyle(HLColor.statusBad)
            .accessibilityIdentifier(identifier)
    }

    private func save() async {
        let value: MeasurementValue
        if kind == .bloodPressure,
           let s = LocaleDecimalParser.parse(systolic),
           let d = LocaleDecimalParser.parse(diastolic)
        {
            // Audit v0162 H-5 — inverse-convert the typed mmHg|kPa values to the
            // canonical mmHg the server + HealthKit expect. Identity for mmHg.
            value = .bloodPressure(
                systolic: units.canonicalBloodPressure(fromDisplayed: s),
                diastolic: units.canonicalBloodPressure(fromDisplayed: d)
            )
        } else if kind == .painNRS {
            // v0158 — pain NRS: persist the clamped 0–10 integer as a scalar.
            value = .scalar(Double(PainScoreInput.clamp(painScore)))
        } else if let v = LocaleDecimalParser.parse(scalar) {
            // Audit v0162 H-5 — inverse-convert the typed value FROM the user's
            // preferred unit TO canonical (kg / mg/dL) before storing, so a
            // non-default unit pref no longer silently corrupts the record.
            // Identity for default (canonical) units.
            value = .scalar(MeasureEntryConversion.canonicalScalar(v, kind: kind, units: units))
        } else {
            return
        }
        // T-2 — propagate the glucose-context intent only when actually
        // entering a glucose measurement. Store guards this too, but the
        // explicit check here keeps the UI's "kind→fields" contract obvious.
        let contextForCapture: GlucoseContext? = kind == .glucose ? glucoseContext : nil
        let ok = await store.capture(
            kind: kind,
            value: value,
            note: note.isEmpty ? nil : note,
            glucoseContext: contextForCapture,
            // Item 1.4b — the operator-chosen instant, not an implicit `.now`.
            recordedAt: recordedAt
        )
        if ok {
            // H1 — remember this kind as last-used + push it to the front of
            // the recent-kinds MRU so the next open defaults here and the chip
            // row surfaces it.
            persistRecentKind(kind)
            saveOk &+= 1
            dismiss()
        } else {
            saveErr &+= 1
            // v0.5.5.2 — surface the store's error in the banner. Fall
            // back to a generic `.unknown` if the store didn't record
            // one (defensive — `capture(...)` always sets `.error` on a
            // false return today, but the fallback keeps the banner
            // honest if that contract drifts).
            saveError = store.error ?? .unknown(
                String(localized: "Save failed. Please try again.")
            )
        }
    }
}

struct HLNumericField: View {
    let title: String
    let placeholder: String
    /// Audit v0162 H-5 — optional unit suffix rendered inside the field's
    /// trailing edge (e.g. "kg", "mmol/L", "mmHg"), so the operator always
    /// knows which unit they're typing in. `nil` renders no suffix.
    var unit: String?
    @Binding var value: String

    /// Eingabe-Größe pixel-1:1 bei Default, skaliert mit Dynamic-Type (Audit M5).
    @ScaledMetric(relativeTo: .title2) private var inputSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(title)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
            HStack(spacing: HLSpace.xs) {
                TextField(placeholder, text: $value)
                    .keyboardType(.decimalPad)
                    .font(.hlMetric(inputSize))
                    .foregroundStyle(HLText.primary)
                if let unit, !unit.isEmpty {
                    Text(unit)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(HLSpace.md)
            .background(HLSurface.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
    }
}
