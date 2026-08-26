import SwiftUI

/// v0.11 W-B — contextual, single-metric target-band editor.
///
/// Replaces the retired multi-metric `TargetEditorSheet` (W-A). The editor
/// now opens from the metric it belongs to — the "Adjust target range" button
/// on the `InsightsTargetReferencePanel` inside `ChartDetailScreen` — mirroring
/// the web, where the `/targets` page was dropped and `MetricTargetSummary`
/// mounts a per-metric `TargetEditSheet` inline.
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
    @Environment(\.dismiss) private var dismiss
    /// QoL-4 (A360-4) — routes the empty-state CTA to the capture picker so the
    /// "no editable targets yet" state has a next step (log a value) instead of
    /// a dead-end. App-root injected, available on this sheet.
    @Environment(AppRouter.self) private var router

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
            Group {
                if metrics.isEmpty {
                    emptyState
                } else {
                    form
                }
            }
            .hlScrollEdgeSoft()
            // #51 — the metric title + the full description now render in an
            // in-content header block (`headerBlock`, `metricHeader` style)
            // inside the Form, NOT as an inline `.navigationTitle`. The old
            // inline title forced the description into a truncating footer
            // caption ("…ppp" — the operator could not read it); the header
            // block paints the large localized title with the full description
            // paragraph below it, never clipped (`.fixedSize`).
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
            // #51 — the heading + full description live in a borderless Section
            // at the top of the Form (no row chrome), mirroring the metric
            // page's `metricHeader` + description: large localized title, then
            // the full description paragraph below it. The description was
            // formerly a truncating footer caption ("…ppp"); here it is promoted
            // to the description slot and never clipped (`.fixedSize`).
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
    /// large localized title at top, the full description paragraph below in
    /// `.hlBody` / `HLText.secondary`, never truncated (`.fixedSize`).
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Text(verbatim: titleText)
                .font(.hlLargeTitle)
                .foregroundStyle(HLText.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("target-editor.title")
            Text("Set your personal target range per value. Changes are saved and synced immediately.")
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("target-editor.description")
        }
        .textCase(nil)
        .padding(.bottom, HLSpace.sm)
    }

    private func metricSection(_ metric: ThresholdMetric) -> some View {
        let bounds = metric.bounds
        let draft = drafts[metric.rawValue] ?? Draft(min: "", max: "")
        return Section {
            HStack(spacing: HLSpace.sm) {
                fieldColumn(
                    titleKey: "Min",
                    text: bindingFor(metric, keyPath: \.min),
                    accessibilityID: "target-editor.\(metric.rawValue).min"
                )
                Text("–")
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
                fieldColumn(
                    titleKey: "Max",
                    text: bindingFor(metric, keyPath: \.max),
                    accessibilityID: "target-editor.\(metric.rawValue).max"
                )
                Text(bounds.unit)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            saveRow(metric: metric, draft: draft)
        } header: {
            Text(LocalizedStringKey(metric.displayNameKey))
                .textCase(nil)
        } footer: {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                if let currentHint = currentValueHint(metric) {
                    Text(currentHint)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary.opacity(0.7))
                }
                Text(boundsHint(metric))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }

    /// #32 — a faint greyed reference to where the metric's measured value
    /// currently sits ("Currently: 72.8 mg/dL"), so the operator can place
    /// their target band against the real series. `nil` when no current value
    /// was supplied (hides the hint).
    private func currentValueHint(_ metric: ThresholdMetric) -> String? {
        guard let value = currentValues[metric.rawValue] else { return nil }
        return String(
            format: String(localized: "Currently: %@ %@"),
            Self.format(value),
            metric.bounds.unit
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
        let parsed = parsedBand(draft)
        let isValid = parsed.flatMap { UserThresholdsStore.validate($0, for: metric) } != nil
        let isDirty = parsed != store.band(for: metric)
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

    private var emptyState: some View {
        // Audit-01 C1/H4 — the canonical `HLEmptyState` lockup (the bespoke
        // stack used a raw `.system(.largeTitle)` glyph + its own type recipe).
        HLEmptyState(
            icon: "slider.horizontal.3",
            title: "No editable targets yet",
            message: "Once you log values, you can set your personal target ranges here."
        ) {
            // QoL-4 — a next-step CTA: dismiss + open the capture picker so the
            // user can log the first value the target band needs.
            HLButton(
                String(localized: "Log a measurement"),
                icon: "plus",
                variant: .restrained
            ) {
                dismiss()
                router.requestCapture()
            }
            .accessibilityIdentifier("target-editor.empty.log")
        }
        .padding(.horizontal, HLSpace.xl)
        .containerCentered()
        .hlScreenBackground()
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
            seeded[metric.rawValue] = Draft(
                min: Self.format(band.min),
                max: Self.format(band.max)
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

    private func parsedBand(_ draft: Draft) -> ThresholdRange? {
        guard let lo = Self.parse(draft.min), let hi = Self.parse(draft.max) else { return nil }
        return ThresholdRange(min: lo, max: hi)
    }

    private func boundsHint(_ metric: ThresholdMetric) -> String {
        let b = metric.bounds
        return String(
            format: String(localized: "Allowed range: %@ – %@ %@"),
            Self.format(b.min),
            Self.format(b.max),
            b.unit
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

    /// #51 — the `MetricKind` whose LOCALIZED `displayName` titles the editor
    /// sheet for a given server target `type`. The server `TargetItem.label` is
    /// an English wire string (`InsightsTargetsDTO.swift:46`), so hosts that
    /// only hold a `type` (the inline `InsightsTargetReferencePanel`) map it back
    /// to its kind and use `kind.displayName` for the heading. `nil` for target
    /// types with no single owning kind — the caller then falls back to the
    /// server label.
    nonisolated static func titleKind(forTargetType type: String) -> MetricKind? {
        switch type {
        case "WEIGHT": .weight
        case "PULSE": .pulse
        case "RESTING_HR": .restingHeartRate
        case "ACTIVITY_STEPS": .steps
        case "BODY_FAT": .bodyFat
        case "SLEEP_DURATION": .sleep
        case "BLOOD_PRESSURE": .bloodPressure
        default: nil
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
