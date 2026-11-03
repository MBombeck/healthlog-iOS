import SwiftUI

// MARK: - Coach provenance + token-usage surfaces (CO4 / CO5 — v0154)

// Split out of `AskCoachSheet+Transcript.swift` (v0154) to keep that file under
// the SwiftLint 600-line ceiling after the provenance disclosure + token footer
// landed. These were `private` to the transcript file; moving them to their own
// file in the same module they become module-internal — `CoachTranscriptView`
// still mounts them, so they cannot be `private` across files.

#if canImport(SpeziChat)
    /// **CO4 (v0154)** — the "what I'm looking at" toggle under a server-arm
    /// assistant reply, mirroring the web coach's `<details>` evidence block.
    /// Collapsed by default (privacy doctrine — never auto-expand the raw
    /// keyValues). 1.4 B2-c: the toggle sits in the reply's one action row
    /// (`CoachReplyActions`) and the body opens below that row.
    struct CoachProvenanceToggle: View {
        @Binding var expanded: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
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
                .frame(minHeight: 44)
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
    }

    /// **CO4** — the expanded evidence: metric/window/`n=count` chips
    /// (monochrome capsules, SF-symbol shape not colour) + the load-bearing
    /// keyValues rows (value + unit, window as a parenthetical tail).
    struct CoachProvenanceBody: View {
        let provenance: CoachServerService.CoachProvenance

        /// Is there anything to show once the toggle is tapped? Drives whether
        /// the toggle renders at all (M1, fix round 1: a windows-only envelope
        /// used to offer a chevron that expanded into blank space).
        static func hasContent(_ provenance: CoachServerService.CoachProvenance) -> Bool {
            !chips(for: provenance).isEmpty || !(provenance.keyValues?.isEmpty ?? true)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                let chips = Self.chips(for: provenance)
                if !chips.isEmpty {
                    chipFlow(chips)
                }
                if let keyValues = provenance.keyValues, !keyValues.isEmpty {
                    VStack(alignment: .leading, spacing: HLSpace.xs) {
                        ForEach(keyValues) { keyValue in
                            keyValueRow(keyValue)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        /// Pairs each metric with the first window (web parity: a single
        /// window-per-metric) + its sample count when present.
        ///
        /// **M1 (fix round 1)** — when the envelope names windows but no
        /// metrics, the windows become the chips rather than nothing.
        static func chips(for provenance: CoachServerService.CoachProvenance) -> [ProvenanceChipModel] {
            let primaryWindow = provenance.windows.first
            guard !provenance.metrics.isEmpty else {
                return provenance.windows.map { window in
                    ProvenanceChipModel(metricToken: "", windowToken: window, count: nil)
                }
            }
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
        private func chipFlow(_ chips: [ProvenanceChipModel]) -> some View {
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
                // M1 — a window-only chip carries no metric token; it renders as
                // the window alone rather than with a stray leading separator.
                // U5 (1.1.1) — the parts are joined by a trailing comma on the
                // preceding part, never by a middle dot.
                if !model.metricToken.isEmpty {
                    Text(Self.joined(
                        CoachProvenanceLabels.metric(model.metricToken),
                        followed: model.windowToken != nil || model.count != nil
                    ))
                    .foregroundStyle(HLText.secondary)
                }
                if let windowToken = model.windowToken {
                    Text(Self.joined(CoachProvenanceLabels.window(windowToken), followed: model.count != nil))
                        .foregroundStyle(HLText.tertiary)
                }
                if let count = model.count {
                    Text(verbatim: "n=\(count)")
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

        private static func joined(_ part: String, followed: Bool) -> String {
            followed ? part + "," : part
        }
    }

    // 1.4 B2-c — the per-turn token footer (CO5) is gone: a token count is
    // developer information, not something the reader of an answer needs.

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
