import SwiftUI

struct MeasureSheetView: View {
    @Environment(MeasurementsStore.self) var store
    /// The user's display-unit prefs (kg|lb / mmHg|kPa /
    /// mg/dL|mmol/L). Threaded in so the entry path can inverse-convert the
    /// typed value FROM the preferred unit TO canonical before storing +
    /// range-validating, mirroring the display path's forward conversion.
    /// `.standard` (canonical identity) when there's no store handle.
    @Environment(\.unitPreferences) var units
    /// Optional type-prefill. When set (e.g. the Home
    /// Vorsorge tile's "jetzt messen" for a due BP reminder), the picker seeds
    /// to this kind ONCE on appear, overriding the last-used-kind restore so the
    /// operator lands directly on the metric the reminder targets. `nil` keeps
    /// the existing last-used-kind behaviour for the central Erfassen path.
    var initialKind: MetricKind?
    /// Last-used metric kind, persisted across sheet opens
    /// so the morning weigh-in stops re-resetting to Blutdruck. `@AppStorage`
    /// (UI-pref only, PROJECT_GUIDE.md-allowed). Seeds `kind` in `.task` before the
    /// keyboard settles; updated on every successful save.
    @AppStorage("measure.lastKind") private var lastKindRaw: String = MetricKind.bloodPressure.rawValue
    /// Recent distinct kinds (MRU, newest-first, comma-joined raw values,
    /// capped at `Self.recentKindLimit`), the stand-in for the recent rows
    /// until the store holds manual readings. Also a UI-pref. Updated
    /// alongside `lastKindRaw` on save.
    @AppStorage("measure.recentKinds") var recentKindsRaw: String = ""
    @State var kind: MetricKind = .bloodPressure
    /// True once `.task` has seeded `kind` from `lastKindRaw`, so the seeding
    /// runs exactly once and a later user pick isn't clobbered.
    @State private var didSeedKind = false
    @State var systolic: String = ""
    @State var diastolic: String = ""
    @State var scalar: String = ""
    /// Pain NRS picker selection (0–10 integer). Separate from `scalar`
    /// because pain is captured via a wheel picker, not the decimal text field.
    @State var painScore: Int = 0
    @State var note: String = ""
    /// **Build 1 / item 1.4b — backdating.** The capture path hard-coded
    /// `recordedAt: .now` (`MeasurementsStore+QuickCapture.swift`), so the only
    /// way to log yesterday's weigh-in was save-then-edit. Web has carried the
    /// field plus an explicit hint since `measurement-form.tsx:539-560`.
    @State var recordedAt: Date = .now
    /// Future bound for the timestamp picker (web: `max={getDefaultMeasuredAt…}`,
    /// mirroring the server's `validateEntryInstant`). Held in state so the range
    /// doesn't churn per render; refreshed when the sheet settles.
    @State private var recordedAtBound: Date = .now
    /// Glucose-context picker selection, `nil` until the person picks one.
    /// The server requires a context on a hand-entered glucose reading, so
    /// there is no "no context" here. Until a pick the form shows the web's
    /// default for the reading's time (``GlucoseContextDefault``), not a fixed
    /// "Random", so an evening reading nobody touched is not filed as fasting.
    @State var pickedGlucoseContext: GlucoseContext?
    /// The receipt after "Save and next" stands in the sheet, which covers
    /// the shell's toast slot; a save that closes the sheet leaves it to the
    /// shell.
    @State var showsReceiptInSheet = false
    /// v0.5.5.1 haptic migration: save-outcome triggers for declarative
    /// `.sensoryFeedback`. Replaces the legacy
    /// `UINotificationFeedbackGenerator().notificationOccurred(.success/.error)`
    /// pair so SwiftUI manages prepare-and-fire + Reduce-Motion semantics.
    @State var saveOk: Int = 0
    /// Set once the value is saved: the drawn check stands over the form for
    /// a moment before the sheet closes.
    @State var isSaved = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var saveErr: Int = 0
    /// Visible save-error surface. Before this fix, a failed
    /// `store.capture(...)` only triggered the error-haptic — there was
    /// no banner, no inline text, no toast (PROJECT_GUIDE.md anti-pattern:
    /// "silent error swallowing"). We now mirror the store error into
    /// local state, render an `ErrorBanner` overlay at the top, and
    /// auto-clear it on the next user input so the operator never gets
    /// stuck reading a stale failure after they typed past it.
    @State var saveError: HLError?
    /// Holds the save in flight, so a second tap on a slow network cannot log
    /// the same reading twice.
    @State var saveGate = FormSaveGate()
    @FocusState var primaryFocused: Bool
    /// The form's measured height, bar included, so a form sheet stands as
    /// tall as its sections. `nil` until the first measure lands.
    @State private var measuredHeight: CGFloat?

    var body: some View {
        HLSheetScaffold(
            "Measurement",
            size: .formMeasured(height: measuredHeight),
            action: .save(isEnabled: canSave) { await save() },
            isDirty: isDirty
        ) {
            Form {
                Section {
                    // #191 QoL — the kinds logged by hand, as rows with the
                    // last reading: one tap switches the form, so the common
                    // case (Gewicht / Blutdruck / Glukose) is a single tap
                    // instead of a menu dive. Hidden until there's history.
                    MeasureRecentKindRows(kinds: recentKinds, lastReadings: recentLastReadings, selection: $kind)
                    Picker(selection: $kind) {
                        ForEach(supportedKinds) { k in
                            Label(k.displayName, systemImage: symbol(for: k)).tag(k)
                        }
                    } label: {
                        HLRowTitle("Metric")
                    }
                    .pickerStyle(.menu)
                }
                .hlFormRowSurface()

                Section {
                    if kind == .bloodPressure {
                        // At the accessibility sizes the two fields stand
                        // one above the other: side by side the unit was cut
                        // to „80 m" and the titles broke into syllables.
                        HLAdaptiveStack { stacked in
                            HLNumericField(title: String(localized: "Systolic"), placeholder: "120", value: $systolic)
                                .focused($primaryFocused)
                                .accessibilityIdentifier("measure-sheet.systolic.field")
                            if !stacked {
                                Text("/").foregroundStyle(HLText.secondary)
                            }
                            // Surface the BP unit suffix (mmHg|kPa) on the
                            // trailing leg so the operator knows which unit both
                            // fields are in.
                            HLNumericField(
                                title: String(localized: "Diastolic"),
                                placeholder: "80",
                                unit: units.bloodPressure.unitSuffix,
                                value: $diastolic
                            )
                        }
                        // Per-component inline range hint.
                        // Without this the operator can submit a 30/200
                        // pair (or a typo'd 1234 systolic) and only find
                        // out via the server 422.
                        if let err = systolicErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.systolic.error")
                        }
                        if let err = diastolicErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.diastolic.error")
                        }
                        lastValueLine
                    } else if kind == .painNRS {
                        // Bespoke 0–10 integer NRS picker. The server
                        // accepts any 0–10 float, so the integer constraint is a
                        // client responsibility: a wheel picker can only yield a
                        // valid 0…10 integer (no decimal text field for pain).
                        painNRSPicker
                        lastValueLine
                    } else {
                        // Show the entry-unit suffix so the operator knows
                        // which unit they're typing (kg|lb, mg/dL|mmol/L, …).
                        HLNumericField(
                            title: kind.displayName,
                            placeholder: placeholder,
                            unit: MeasureEntryConversion.entrySuffix(kind: kind, units: units),
                            value: $scalar
                        )
                        .focused($primaryFocused)
                        .accessibilityIdentifier("measure-sheet.scalar.field")
                        // Inline range hint when the scalar
                        // sits outside the per-kind sane range. Submit
                        // stays disabled (`canSave`) until the operator
                        // either fixes the value or clears the field.
                        if let err = scalarErrorMessage {
                            inlineRangeError(err, identifier: "measure-sheet.scalar.error")
                        }
                        lastValueLine
                    }
                } header: {
                    HLSectionHeader("Value")
                }
                .hlFormRowSurface()

                if kind == .glucose {
                    Section {
                        Picker(selection: glucoseContextSelection) {
                            ForEach(GlucoseContext.allCases) { context in
                                Text(context.displayResource).tag(context)
                            }
                        } label: {
                            HLRowTitle("Context")
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("measure-sheet.glucose-context.picker")
                    } header: {
                        HLSectionHeader("Context")
                    }
                    .hlFormRowSurface()
                }

                // Item 1.4b — backdating. Bounded to "not in the future". 1.4
                // B2: no footer; the date control is visibly adjustable on iOS.
                Section {
                    DatePicker(
                        selection: $recordedAt,
                        in: ...recordedAtBound,
                        displayedComponents: [.date, .hourAndMinute]
                    ) {
                        HLRowTitle("measurement.form.recordedAt.label")
                    }
                    .accessibilityIdentifier("measure-sheet.recordedAt.picker")
                } header: {
                    HLSectionHeader("measurement.form.recordedAt.section")
                }
                .hlFormRowSurface()

                Section {
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(2 ... 4)
                        .accessibilityIdentifier("measure-sheet.note")
                } header: {
                    HLSectionHeader("Note")
                }
                .hlFormRowSurface()

                saveAndNextSection
            }
            .hlPageMargins()
            // iOS 26+ soft scroll-edge so the Form blurs into
            // the sheet's Liquid Glass header instead of clipping cleanly.
            .hlScrollEdgeSoft()
            // The rows' height and the insets around them (the bar above, the
            // page margins): one measure, in the form's own scroll geometry,
            // so the sheet's slide-in does not move it.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                HLSheet.formHeight(contentHeight: geometry.contentSize.height, topInset: geometry.contentInsets.top)
            } action: { _, height in
                measuredHeight = height
            }
            // The keyboard comes after the sheet has settled, so it does not
            // fight the detent transition; a form sheet waits for a tap.
            .hlFocusOnSettle($primaryFocused)
        }
        .task {
            // Seed the picker from the last-used kind exactly once, before
            // the keyboard settles. A later user pick is preserved (`didSeedKind`).
            if !didSeedKind {
                // An explicit prefill (Vorsorge "jetzt messen")
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
        }
        // v0.5.5.1 haptic migration: declarative success/error feedback on
        // save outcome.
        .sensoryFeedback(.success, trigger: saveOk)
        .sensoryFeedback(.error, trigger: saveErr)
        // The saved value's confirmation: the same drawn check as a taken
        // dose and a logged mood, in the middle of the sheet.
        .overlay {
            // Always there, held undrawn, so it draws itself on when the
            // save lands.
            HLConfirmGlyph(isConfirmed: isSaved)
                .font(.hlIcon(HLIconSize.cover))
                .foregroundStyle(HLColor.statusOK)
                // A calm disc under the check, as on the mood face, so it
                // never stands on the form's text; only once it is saved.
                .padding(HLSpace.md)
                .background(Circle().fill(HLSurface.primary).opacity(isSaved ? 1 : 0))
                .allowsHitTesting(false)
        }
        // The receipt of a "Save and next": value and Undo, in the sheet the
        // person keeps typing in (the shell's slot sits under the sheet).
        .overlay(alignment: .bottom) { receiptInSheet }
        .hlAnimation(HLMotion.spring, value: store.undoCoordinator?.current?.id)
        // Surface the save error visually. Before this the
        // operator only got a haptic; the banner makes the failure
        // legible so they know what went wrong + can retry.
        // The banner below still presents as this overlay; this
        // reserves its height at the top so it covers nothing.
        .hlReserveErrorBannerSpace(saveError)
        .overlay(alignment: .top) {
            // Give the save-error banner an explicit way forward.
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
    var supportedKinds: [MetricKind] {
        [
            .bloodPressure, .pulse, .restingHeartRate, .hrv, .respiratoryRate, .glucose, .spo2, .bodyTemperature,
            // Pain NRS is a manual symptom signal; sits with the vitals.
            .painNRS,
            .weight, .bodyFat, .bodyWater, .boneMass,
            // Waist circumference + grip strength are manual clinical
            // signals (HK-less / HK-deferred). Waist-to-height is render-only and
            // intentionally absent here (no manual-entry path).
            .waistCircumference, .gripStrength,
            .vo2Max
        ]
    }

    // MARK: - Recent-kinds chips

    /// Max distinct kinds kept in the recent-kinds MRU + shown as chips.
    private static let recentKindLimit = 5

    /// Persist `picked` as last-used + move it to the front of the recent MRU,
    /// de-duping and capping at `recentKindLimit`.
    func persistRecentKind(_ picked: MetricKind) {
        lastKindRaw = picked.rawValue
        recentKindsRaw = MeasureRecentKinds.push(
            picked,
            into: recentKindsRaw,
            allowed: supportedKinds,
            limit: Self.recentKindLimit
        )
    }

    /// 0–10 integer NRS pain picker. A wheel picker structurally
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
                .hlText(.rowSubtitle)
        }
    }

    private func symbol(for k: MetricKind) -> String {
        // Single source of truth — pull from the descriptor catalog rather
        // than maintain a parallel switch that drifts whenever a new kind
        // joins the registry. The catalog already supplies SF Symbols for
        // every kind (locked in by `MetricKindDescriptorRegistryTests`).
        k.descriptor.sfSymbol
    }

    /// Example placeholder per kind. The descriptor catalog
    /// doesn't carry a textfield placeholder yet (it surfaces `unitLabel`,
    /// `title`, empty-state copy), and the values here are user-friendly
    /// "typical" examples rather than canonical defaults. Kept inline so a
    /// reader can scan the picker contents without leaving the sheet file.
    ///
    /// The examples are canonical (kg, °C, cm, mg/dL). On an
    /// account that reads another unit the example converts with the field's
    /// own unit, so a °F field never suggests "36,8".
    private var placeholder: String {
        Self.placeholder(for: kind, units: units)
    }

    /// The example value in the unit the user types in; the edit sheet shows
    /// the same one.
    static func placeholder(for kind: MetricKind, units: UnitPreferences) -> String {
        let transform = units.transform(for: kind)
        guard transform.rescales, let example = MeasurePlaceholder.examples[kind],
              let converted = transform.formatted(example.value) else { return MeasurePlaceholder.text(kind) }
        return converted
    }

    /// Whether anything was entered, for the discard guard. The kind and the
    /// time are where the sheet opens, so only a typed value or note counts.
    private var isDirty: Bool {
        !systolic.isEmpty || !diastolic.isEmpty || !scalar.isEmpty || painScore != 0 || !note.isEmpty
    }

    /// **Submit-gate now honors per-kind sane-range validation.**
    /// Before this the operator could type `-500` weight or `99999`
    /// glucose, hit Speichern, and only learn the value was out-of-range
    /// from the server 422. We now refuse the submit client-side and keep
    /// the inline error hint visible until the value lands inside the
    /// range OR the field is cleared.
    var canSave: Bool {
        if kind == .bloodPressure {
            // Validate in canonical mmHg space (inverse-converting the
            // typed mmHg|kPa value first) so a kPa entry isn't wrongly blocked.
            let s = MeasureEntryValidation.validateBloodPressure(systolic, component: .systolic, units: units)
            let d = MeasureEntryValidation.validateBloodPressure(diastolic, component: .diastolic, units: units)
            return s == .ok && d == .ok
        }
        // Pain NRS is captured via the wheel picker; any picked value is
        // a valid 0…10 integer, so the submit gate is always open (0 = no pain).
        if kind == .painNRS {
            return PainScoreInput.isValid(painScore)
        }
        // Validate against the canonical range in canonical unit space
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
        HLFormErrorText(message)
            .font(.hlCaption)
            .accessibilityIdentifier(identifier)
    }
}

struct HLNumericField: View {
    let title: String
    let placeholder: String
    /// Optional unit suffix rendered inside the field's
    /// trailing edge (e.g. "kg", "mmol/L", "mmHg"), so the operator always
    /// knows which unit they're typing in. `nil` renders no suffix.
    var unit: String?
    @Binding var value: String

    /// Eingabe-Größe pixel-1:1 bei Default, skaliert mit Dynamic-Type (Audit M5).
    @ScaledMetric(relativeTo: .title2) private var inputSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(title)
                .hlText(.rowSubtitle)
            HStack(spacing: HLSpace.xs) {
                TextField(placeholder, text: $value)
                    .keyboardType(.decimalPad)
                    .font(.hlMetric(inputSize))
                    .foregroundStyle(HLText.primary)
                if let unit, !unit.isEmpty {
                    // The unit is never cut; the number field gives way.
                    Text(unit)
                        .hlText(.factLabel)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
            .padding(HLSpace.md)
            .background(HLSurface.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        }
    }
}
