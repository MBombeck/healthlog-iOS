import SwiftUI

// MARK: - Coach provenance + token-usage surfaces (CO4 / CO5 — v0154)

// Split out of `AskCoachSheet+Transcript.swift` (v0154) to keep that file under
// the SwiftLint 600-line ceiling after the provenance disclosure + token footer
// landed. These were `private` to the transcript file; moving them to their own
// file in the same module they become module-internal — `CoachTranscriptView`
// still mounts them, so they cannot be `private` across files.

#if canImport(SpeziChat)
    /// **CO4 (v0154)** — the collapsed "what I'm looking at" disclosure under a
    /// server-arm assistant reply, mirroring the web coach's `<details>` evidence
    /// block. Collapsed by default (privacy doctrine — never auto-expand the raw
    /// keyValues). Expanded body: metric/window/`n=count` chips (monochrome
    /// capsules, SF-symbol shape not colour) + the load-bearing keyValues rows
    /// (value + unit, window as a parenthetical tail). DS-tokened throughout.
    struct CoachProvenanceDisclosure: View {
        let provenance: CoachServerService.CoachProvenance
        @State private var expanded = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                disclosureHeader
                if expanded {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        if !chips.isEmpty {
                            chipFlow
                        }
                        if let keyValues = provenance.keyValues, !keyValues.isEmpty {
                            VStack(alignment: .leading, spacing: HLSpace.xs) {
                                ForEach(keyValues) { keyValue in
                                    keyValueRow(keyValue)
                                }
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.leading, HLSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var disclosureHeader: some View {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: HLSpace.xs) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.hlIcon(HLIconSize.sm))
                        .foregroundStyle(HLText.secondary)
                    Text(String(localized: "insights.coach.evidenceLabel"))
                        .font(.hlFootnote)
                        .foregroundStyle(HLText.secondary)
                    HLDisclosureChevron()
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "insights.coach.evidenceLabel"))
            .accessibilityValue(
                expanded
                    ? String(localized: "coach.evidence.expanded")
                    : String(localized: "coach.evidence.collapsed")
            )
            .accessibilityAddTraits(.isButton)
        }

        /// Pairs each metric with the first window (web parity: a single
        /// window-per-metric) + its sample count when present.
        private var chips: [ProvenanceChipModel] {
            let primaryWindow = provenance.windows.first
            return provenance.metrics.map { metric in
                ProvenanceChipModel(
                    metricToken: metric,
                    windowToken: primaryWindow,
                    count: provenance.counts?[metric]
                )
            }
        }

        /// Horizontal chip strip — the canonical app chip-row pattern
        /// (`SourcesChipStrip`): a non-clipping horizontal scroll so a handful of
        /// metric chips never reflow the bubble column or get truncated.
        private var chipFlow: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HLSpace.xs) {
                    ForEach(chips) { model in
                        ProvenanceChip(model: model)
                    }
                }
                .padding(.horizontal, HLSpace.hair) // hairline so chip-borders aren't clipped
            }
        }

        private func keyValueRow(_ keyValue: CoachServerService.CoachKeyValue) -> some View {
            // Lead with the value (web parity), window in a parenthetical tail.
            (
                Text(keyValue.label + ": ")
                    .foregroundStyle(HLText.secondary)
                    + Text(valueText(keyValue))
                    .foregroundStyle(HLText.primary)
                    + Text(windowTail(keyValue))
                    .foregroundStyle(HLText.secondary)
            )
            .font(.hlFootnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }

        private func valueText(_ keyValue: CoachServerService.CoachKeyValue) -> String {
            if let unit = keyValue.unit, !unit.isEmpty {
                return keyValue.value + "\u{00A0}" + unit
            }
            return keyValue.value
        }

        private func windowTail(_ keyValue: CoachServerService.CoachKeyValue) -> String {
            guard let window = keyValue.window, !window.isEmpty else { return "" }
            let label = CoachProvenanceLabels.window(window)
            return " (" + label + ")"
        }
    }

    /// **CO4** — render-data for one provenance chip. A plain `Sendable` value
    /// (not a `View`), so its `Identifiable` conformance stays off the MainActor
    /// — the `ProvenanceChip` view consumes it inside a `ForEach`.
    struct ProvenanceChipModel: Identifiable {
        let metricToken: String
        let windowToken: String?
        let count: Int?

        var id: String {
            metricToken + "|" + (windowToken ?? "none")
        }
    }

    /// **CO4** — one monochrome provenance chip: metric label + optional window +
    /// optional `n=count`. Capsule on `HLSurface.secondary`, `.hlCaption` ink —
    /// matches the app's neutral chip recipe (shape, not colour).
    struct ProvenanceChip: View {
        let model: ProvenanceChipModel

        var body: some View {
            HStack(spacing: HLSpace.xxs) {
                Text(CoachProvenanceLabels.metric(model.metricToken))
                    .foregroundStyle(HLText.secondary)
                if let windowToken = model.windowToken {
                    Text("· " + CoachProvenanceLabels.window(windowToken))
                        .foregroundStyle(HLText.tertiary)
                }
                if let count = model.count {
                    Text("· n=\(count)")
                        .foregroundStyle(HLText.tertiary)
                        .monospacedDigit()
                }
            }
            .font(.hlCaption)
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xxs)
            .background(HLSurface.secondary, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Token footer (CO5 / v0154)

    /// **CO5 (v0154)** — the quiet per-turn token-usage caption under a
    /// server-arm reply, mirroring the web `MessageTokenFooter`. Renders nothing
    /// when there is no count (the store only stashes usage with a non-nil
    /// total). `.hlCaption` + `HLText.tertiary`, monospaced digits (web's
    /// `tabular-nums`).
    struct CoachTokenFooter: View {
        let usage: CoachServerService.CoachUsage

        var body: some View {
            if let total = usage.totalTokens {
                Text(label(total))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
                    .padding(.leading, HLSpace.md)
                    .accessibilityLabel(label(total))
            }
        }

        private func label(_ total: Int) -> String {
            if let model = usage.model, !model.isEmpty {
                return String(
                    localized: "\(total) tokens · \(model)",
                    comment: "CO5 — quiet per-turn token-usage footer with provider model."
                )
            }
            return String(
                localized: "\(total) tokens",
                comment: "CO5 — quiet per-turn token-usage footer."
            )
        }
    }

    // MARK: - Provenance label resolver (CO4)

    /// **CO4** — resolves provenance metric / window tokens to their localized
    /// labels via the `insights.coach.metric.*` / `insights.coach.window.*` keys
    /// (ported from the web messages). Falls back to the raw token when a key is
    /// missing, matching the web resolver.
    enum CoachProvenanceLabels {
        static func metric(_ token: String) -> String {
            resolve(prefix: "insights.coach.metric.", token: token)
        }

        static func window(_ token: String) -> String {
            resolve(prefix: "insights.coach.window.", token: token)
        }

        private static func resolve(prefix: String, token: String) -> String {
            let key = prefix + token
            let resolved = String(localized: String.LocalizationValue(key))
            // `String(localized:)` echoes the key verbatim when the catalog has
            // no entry → fall back to the raw token (web parity).
            return resolved == key ? token : resolved
        }
    }
#endif
