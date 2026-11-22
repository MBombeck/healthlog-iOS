import SwiftUI

// MARK: - Coach provenance + token-usage surfaces

// Split out of `AskCoachSheet+Transcript.swift` to keep that file under
// the SwiftLint 600-line ceiling after the provenance disclosure + token footer
// landed. These were `private` to the transcript file; moving them to their own
// file in the same module they become module-internal — `CoachTranscriptView`
// still mounts them, so they cannot be `private` across files.

#if canImport(SpeziChat)
    /// The expanded evidence: metric/window/`n=count` chips
    /// (monochrome capsules, SF-symbol shape not colour) + the load-bearing
    /// keyValues rows (value + unit, window as a parenthetical tail).
    struct CoachProvenanceBody: View {
        let provenance: CoachServerService.CoachProvenance

        /// Is there anything to show once the disclosure opens? Together with
        /// the trail it decides whether the disclosure renders at all (M1, fix
        /// round 1: a windows-only envelope used to offer a chevron that
        /// expanded into blank space).
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
            let label = Text(keyValue.label + ": ").foregroundStyle(HLText.secondary)
            let value = Text(valueText(keyValue)).foregroundStyle(HLText.primary)
            let window = Text(windowTail(keyValue)).foregroundStyle(HLText.secondary)
            return Text("\(label)\(value)\(window)")
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

    /// Render-data for one provenance chip. A plain `Sendable` value
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

    /// One monochrome provenance chip: metric label + optional window +
    /// optional `n=count`, as the neutral tag capsule (`HLBadge`).
    struct ProvenanceChip: View {
        let model: ProvenanceChipModel

        var body: some View {
            HLBadge(Self.title(model))
        }

        /// A window-only chip carries no metric token; it reads as the window
        /// alone rather than with a stray leading separator. The parts are
        /// joined by a comma, never by a middle dot.
        static func title(_ model: ProvenanceChipModel) -> String {
            let metric = model.metricToken.isEmpty ? nil : CoachProvenanceLabels.metric(model.metricToken)
            let window = model.windowToken.map(CoachProvenanceLabels.window)
            let count = model.count.map { "n=\($0)" }
            return [metric, window, count].compactMap { $0 }.joined(separator: ", ")
        }
    }

    // The per-turn token footer is gone: a token count is
    // developer information, not something the reader of an answer needs.

    // MARK: - Provenance label resolver

    /// Resolves provenance metric / window tokens to their localized
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
