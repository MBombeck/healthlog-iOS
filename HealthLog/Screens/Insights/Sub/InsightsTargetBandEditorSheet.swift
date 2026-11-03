import SwiftUI

/// v0.11 W-B — contextual, single-metric target-band editor.
///
/// Replaces the retired multi-metric `TargetEditorSheet` (W-A). The editor
/// now opens from the metric it belongs to — the header gear on
/// `InsightsMetricScreen` — mirroring the web, where the `/targets` page was
/// dropped and `MetricTargetSummary` mounts a per-metric `TargetEditSheet`
/// inline.
///
/// **Scope:** one editable band per sheet (BP carries the systolic + diastolic
/// pair). Seeded from `UserThresholdsStore`, validated against the metric's
/// physiological `bounds` + `min < max`, persisted server-first through
/// `updateThreshold(_:to:)` (optimistic + outbox replay). On save the
/// `InsightsTargetsStore` is refreshed by the host so the panel repaints
/// against the new band.
///
/// **Why a Form sheet:** matches the iOS settings idiom + the prior
/// `EditMeasurementSheet`, so the muscle memory carries over. Glass discipline:
/// the sheet is system chrome — no glass on its content rows.
struct InsightsTargetBandEditorSheet: View {
    /// The editable threshold metrics this sheet drives. One entry for most
    /// metrics; two for blood pressure (systolic + diastolic).
    let metrics: [ThresholdMetric]
    /// #51 — the LOCALIZED metric title for the sheet heading. Hosts pass
    /// `kind.displayName` (localized, `Measurement.swift:240`), NOT the server
    /// `TargetItem.label` (an English wire string, `InsightsTargetsDTO.swift:46`)
    /// the sheet used to render — the operator saw "Blood Pressure" on a German
    /// device. Rendered as the large in-content heading (`metricHeader` style),
    /// replacing the truncating inline `.navigationTitle`.
    let titleText: String
    /// #32 — the metric's CURRENT measured reference value(s), keyed by
    /// `metric.rawValue` (typically the 30-day average). Rendered as a faint
    /// greyed hint beneath the fields so the operator sees where their values
    /// currently sit — NOT pre-filled into the inputs. Empty hides the hint.
    var currentValues: [String: Double] = [:]

    @Environment(UserThresholdsStore.self) private var store
    /// #115 P2 — the account's display units. Fields, hints and bounds read in
    /// them; the save inverts to canonical (``ThresholdUnitAdapter``).
    @Environment(\.unitPreferences) private var unitPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [String: Draft] = [:]
    /// FORM-1 (Audit v0162) — the seeded draft snapshot; `drafts != seededDrafts`
    /// means the operator typed a band they haven't persisted via the per-metric
    /// Save button yet.
    @State private var seededDrafts: [String: Draft] = [:]
    @State private var showDiscardConfirm = false
    @State private var saveTick: Int = 0
    /// FORM-2 (Audit v0162) — initial focus onto the first metric's Min field
    /// (keyed by the field's accessibility identifier).
    @FocusState private var focusedField: String?

    /// FORM-1 — any editable draft diverges from what was seeded from the store.
    private var isDirty: Bool {
        drafts != seededDrafts
    }

    var body: some View {
        NavigationStack {
            // 1.4 B2 — the sheet opens only from a gear that exists when a
            // metric has an editable band, so the "no editable targets yet"
            // state could never show and is gone.
            form
                .hlScrollEdgeSoft()
                // #51 — the metric title renders in an in-content header block
                // (`headerBlock`, `metricHeader` style) inside the Form, NOT as
                // an inline `.navigationTitle`.
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Done")) {
                            if isDirty { showDiscardConfirm = true } else { dismiss() }
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if store.isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Saving"))
                        }
                    }
                }
                // K1 — the banner below still presents as this overlay; this
                // reserves its height at the top so it covers nothing (H2).
                .hlReserveErrorBannerSpace(store.error)
                .overlay(alignment: .top) {
                    ErrorBanner(error: store.error) {
                        Task {
                            await store.refresh()
                            seedDrafts()
                        }
                    }
                }
                .sensoryFeedback(.success, trigger: saveTick)
                .task {
                    if store.lastLoadedAt == nil { await store.load() }
                    seedDrafts()
                    // FORM-2 — focus the first metric's Min field once seeded.
                    try? await Task.sleep(for: HLSheet.focusDelay)
                    if let first = metrics.first {
                        focusedField = "target-editor.\(first.rawValue).min"
                    }
                }
        }
        // FORM-1 — guard against a swipe-down (or Done) discarding an unsaved
        // draft band; keep the existing in-flight save lock.
        .hlDiscardGuard(isDirty: isDirty, isSaving: store.isSaving, isPresented: $showDiscardConfirm) {
            dismiss()
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            // #51 — the heading lives in a borderless Section at the top of
            // the Form (no row chrome), mirroring the metric page's header.
            Section {
                EmptyView()
            } header: {
                headerBlock
            }
            ForEach(metrics, id: \.rawValue) { metric in
                metricSection(metric)
            }
        }
    }

    /// #51 — in-content header mirroring the metric page (`metricHeader`):
    /// the large localized title. 1.4 B2 — no description under it: the fields
    /// and their "Speichern" say what the sheet does.
    private var headerBlock: some View {
        Text(verbatim: titleText)
            .font(.hlLargeTitle)
            .foregroundStyle(HLText.primary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("target-editor.title")
            .textCase(nil)
            .padding(.bottom, HLSpace.sm)
    }

    private func metricSection(_ metric: ThresholdMetric) -> some View {
        let adapter = metric.unitAdapter(unitPreferences)
        let draft = drafts[metric.rawValue] ?? Draft(min: "", max: "")
        return Section {
            HStack(spacing: HLSpace.sm) {
                fieldColumn(
                    titleKey: "Min",
                    text: bindingFor(metric, keyPath: \.min),
                    accessibilityID: "target-editor.\(metric.rawValue).min"
                )
                Text(String(localized: "range.separator.to"))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                fieldColumn(
                    titleKey: "Max",
                    text: bindingFor(metric, keyPath: \.max),
                    accessibilityID: "target-editor.\(metric.rawValue).max"
                )
                Text(adapter.unit)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            saveRow(metric: metric, draft: draft)
        } header: {
            // 1.4 B2 — where the value stands now sits with the fields it
            // helps to fill, not in a faint footer under them.
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(metric.displayNameKey))
                Spacer(minLength: HLSpace.sm)
                if let currentHint = currentValueHint(metric) {
                    Text(currentHint)
                        .monospacedDigit()
                }
            }
            .textCase(nil)
        } footer: {
            // The allowed range only once an entry falls outside it.
            if isOutOfBounds(draft, metric: metric) {
                Text(boundsHint(metric))
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .accessibilityIdentifier("target-editor.\(metric.rawValue).bounds")
            }
        }
    }

    /// #32 — a faint greyed reference to where the metric's measured value
    /// currently sits ("Currently: 72.8 mg/dL"), so the operator can place
    /// their target band against the real series. `nil` when no current value
    /// was supplied (hides the hint).
    private func currentValueHint(_ metric: ThresholdMetric) -> String? {
        guard let value = currentValues[metric.rawValue] else { return nil }
        let adapter = metric.unitAdapter(unitPreferences)
        return String(
            format: String(localized: "Currently: %@ %@"),
            Self.format(adapter.toDisplay(value)),
            adapter.unit
        )
    }

    private func fieldColumn(
        titleKey: LocalizedStringKey,
        text: Binding<String>,
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(titleKey)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            TextField(titleKey, text: text)
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .focused($focusedField, equals: accessibilityID)
                .accessibilityIdentifier(accessibilityID)
        }
    }

    @ViewBuilder
    private func saveRow(metric: ThresholdMetric, draft: Draft) -> some View {
        let adapter = metric.unitAdapter(unitPreferences)
        let parsed = parsedBand(draft, adapter: adapter)
        let isValid = parsed.flatMap { UserThresholdsStore.validate($0, for: metric) } != nil
        // Dirty in DISPLAY space: an untouched lb draft seeded from 68.0 kg
        // reads 149.9 and inverts to 67.99, which is not an edit.
        let isDirty = parsedDisplayBand(draft) != store.band(for: metric).map {
            ThresholdRange(min: adapter.toDisplay($0.min), max: adapter.toDisplay($0.max))
        }
        Button {
            guard let band = parsed else { return }
            Task {
                let ok = await store.updateThreshold(metric, to: band)
                if ok { saveTick &+= 1 }
            }
        } label: {
            Text("Save")
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .disabled(!isValid || !isDirty || store.isSaving)
        .accessibilityIdentifier("target-editor.\(metric.rawValue).save")
    }

    // MARK: - Drafts + parsing

    private struct Draft: Equatable {
        var min: String
        var max: String
    }

    private func seedDrafts() {
        var seeded: [String: Draft] = [:]
        for metric in metrics {
            guard let band = store.band(for: metric) else { continue }
            let adapter = metric.unitAdapter(unitPreferences)
            seeded[metric.rawValue] = Draft(
                min: Self.format(adapter.toDisplay(band.min)),
                max: Self.format(adapter.toDisplay(band.max))
            )
        }
        drafts = seeded
        // FORM-1 — remember the seeded baseline so we can detect unsaved edits.
        seededDrafts = seeded
    }

    private func bindingFor(
        _ metric: ThresholdMetric,
        keyPath: WritableKeyPath<Draft, String>
    ) -> Binding<String> {
        Binding(
            get: { drafts[metric.rawValue]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var draft = drafts[metric.rawValue] ?? Draft(min: "", max: "")
                draft[keyPath: keyPath] = newValue
                drafts[metric.rawValue] = draft
            }
        )
    }

    /// The draft as typed (display unit), before inversion.
    private func parsedDisplayBand(_ draft: Draft) -> ThresholdRange? {
        guard let lo = Self.parse(draft.min), let hi = Self.parse(draft.max) else { return nil }
        return ThresholdRange(min: lo, max: hi)
    }

    /// The draft inverted to the canonical band the store validates and saves.
    private func parsedBand(_ draft: Draft, adapter: ThresholdUnitAdapter) -> ThresholdRange? {
        parsedDisplayBand(draft).map {
            ThresholdRange(min: adapter.toCanonical($0.min), max: adapter.toCanonical($0.max))
        }
    }

    /// A filled-in draft that does not parse into a band the store accepts.
    /// An empty or half-typed field is not an error yet.
    private func isOutOfBounds(_ draft: Draft, metric: ThresholdMetric) -> Bool {
        guard !draft.min.isEmpty, !draft.max.isEmpty else { return false }
        let adapter = metric.unitAdapter(unitPreferences)
        return parsedBand(draft, adapter: adapter).flatMap { UserThresholdsStore.validate($0, for: metric) } == nil
    }

    private func boundsHint(_ metric: ThresholdMetric) -> String {
        let adapter = metric.unitAdapter(unitPreferences)
        let window = adapter.bounds(metric.bounds)
        return String(
            format: String(localized: "Allowed range: %@ – %@ %@"),
            Self.format(window.min),
            Self.format(window.max),
            adapter.unit
        )
    }

    /// Locale-aware decimal parse — accepts both `,` and `.` as the decimal
    /// separator so a DE keyboard ("72,5") and an EN one ("72.5") both work, and
    /// grouped input ("1.234,5") parses correctly (A360-5 H-4).
    private static func parse(_ s: String) -> Double? {
        LocaleDecimalParser.parse(s)
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)).locale(.current))
    }
}

extension InsightsTargetBandEditorSheet {
    /// Maps an `InsightsTargetsResponseDTO.TargetItem.type` to the editable
    /// `ThresholdMetric`(s) behind it. Blood pressure fans out to the
    /// systolic + diastolic pair; types with no editable band (mood,
    /// compliance, BMI — derived / not directly editable) return `[]`, in which
    /// case the host suppresses the adjust affordance entirely.
    nonisolated static func editableMetrics(forTargetType type: String) -> [ThresholdMetric] {
        switch type {
        case "WEIGHT": [.weight]
        case "PULSE", "RESTING_HR": [.pulse]
        case "BODY_FAT": [.bodyFat]
        case "SLEEP_DURATION": [.sleepDuration]
        case "ACTIVITY_STEPS": [.activitySteps]
        case "BLOOD_PRESSURE": [.bloodPressureSys, .bloodPressureDia]
        default: []
        }
    }
}

private extension ThresholdMetric {
    /// Localized section title key for the editor. Glucose contexts + body
    /// composition need their own keys beyond `MetricTypeLocalisation`.
    var displayNameKey: String {
        switch self {
        case .weight: "Weight"
        case .bloodPressureSys: "Blood pressure (systolic)"
        case .bloodPressureDia: "Blood pressure (diastolic)"
        case .pulse: "Pulse"
        case .bodyFat: "Body fat"
        case .sleepDuration: "Sleep duration"
        case .activitySteps: "Steps"
        case .bloodGlucoseFasting: "Blood glucose (fasting)"
        case .bloodGlucosePostprandial: "Blood glucose (postprandial)"
        case .bloodGlucoseRandom: "Blood glucose (random)"
        case .bloodGlucoseBedtime: "Blood glucose (bedtime)"
        case .totalBodyWater: "Body water"
        case .boneMass: "Bone mass"
        case .oxygenSaturation: "Oxygen saturation"
        }
    }
}
