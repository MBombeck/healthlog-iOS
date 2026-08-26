import SwiftUI

// MARK: - Workout enrichment sections (7.8 — #67)

/// Split note (file_length-discipline): the server-enrichment surfaces
/// (per-km splits, own-history comparison) plus the HR-zone derivation
/// helpers live here so `WorkoutDetailView.swift` stays under the 600-line
/// cap. Pure section move — the `body` in the main file references these
/// members across the extension boundary (same type, same module).
extension WorkoutDetailView {
    // MARK: - HR-zone derivation

    /// Resolve the zone slices to render: the server-computed `zones` win when
    /// present (they carry the `tanaka` computed path too, not just WHOOP), else
    /// the legacy `metadata.zoneDurations` WHOOP map. Positive-only, ordered by
    /// zone index. `nonisolated` — pure derive helper, exercised off-main in
    /// tests.
    nonisolated static func resolvedZones(from workout: WorkoutListEntryDTO) -> [HRZone] {
        if let server = workout.zones, !server.zones.isEmpty {
            let mapped = server.zones.compactMap { band -> HRZone? in
                guard band.seconds > 0 else { return nil }
                return HRZone(index: band.zone, label: zoneLabel(band.zone), seconds: band.seconds)
            }
            .sorted { $0.index < $1.index }
            if !mapped.isEmpty { return mapped }
        }
        return orderedZones(from: workout.metadata?.zoneDurations)
    }

    /// Map the raw `zoneDurations` dict (WHOOP: `zone_zero_milli` …
    /// `zone_five_milli`, milliseconds) into an ordered, labelled, positive-only
    /// list. Sorting by the canonical zone order keeps zone-0 → zone-5 left to
    /// right regardless of dict iteration order.
    nonisolated static func orderedZones(from raw: [String: Double]?) -> [HRZone] {
        guard let raw else { return [] }
        return raw.compactMap { key, millis -> HRZone? in
            guard millis > 0, let index = zoneIndex(for: key) else { return nil }
            return HRZone(index: index, label: zoneLabel(index), seconds: millis / 1000)
        }
        .sorted { $0.index < $1.index }
    }

    /// Parse the zone index out of a WHOOP-style key (`zone_three_milli` → 3).
    ///
    /// Strips the leading `zone` token BEFORE matching number words — otherwise
    /// the literal `"zone"` substring contains `"one"` and every key would
    /// resolve to 1. Matches the remainder against the worded ordinal, then
    /// falls back to a trailing digit (`zone_3`).
    nonisolated static func zoneIndex(for key: String) -> Int? {
        let lowered = key.lowercased()
        // Drop the leading "zone" so "zone_one" → "_one_" and "zone_..." can't
        // false-match the "one" inside "zone".
        let remainder = lowered.replacingOccurrences(of: "zone", with: "")
        let words: [(String, Int)] = [
            ("zero", 0), ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5)
        ]
        for (word, idx) in words where remainder.contains(word) {
            return idx
        }
        // Fallback: a trailing digit (`zone_3`).
        if let digit = remainder.last(where: \.isNumber), let idx = Int(String(digit)) { return idx }
        return nil
    }

    nonisolated static func zoneLabel(_ index: Int) -> String {
        "Z\(index)"
    }

    // MARK: - Splits section (server-computed per-km splits)

    /// Per-kilometre splits from the server `splits[]`. Each row shows the km
    /// index, the split duration, and the unit-adapted pace (min/km · min/mi).
    /// Hidden for indoor / route-less workouts (server sends nil / empty).
    @ViewBuilder
    var splitsSection: some View {
        if let splits = resolved.splits, !splits.isEmpty {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("workout.splits.title")
                        .font(.hlTitle3)
                        .foregroundStyle(HLText.primary)
                    VStack(spacing: HLSpace.xs) {
                        ForEach(splits) { split in
                            splitRow(split)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func splitRow(_ split: WorkoutSplitDTO) -> some View {
        HStack(spacing: HLSpace.sm) {
            Text("workout.splits.km \(split.km)")
                .font(.hlBody.weight(.medium))
                .foregroundStyle(HLText.primary)
            Spacer()
            if let pace = WorkoutFormatter.paceLabel(secondsPerKm: Double(split.paceSecPerKm)) {
                Text(pace)
                    .font(.hlCaption.monospacedDigit())
                    .foregroundStyle(HLText.secondary)
            }
            if let dur = WorkoutFormatter.duration(split.durationSec) {
                Text(dur)
                    .font(.hlBody.monospacedDigit())
                    .foregroundStyle(HLText.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Sport-context section (own-history comparison)

    /// Muted comparison line against the user's own 180-day average for this
    /// sport (server `sportContext`). Comparison is to own history only — never
    /// a population band. Hidden when the server sends no baseline.
    @ViewBuilder
    var sportContextSection: some View {
        // Guard on the avg duration (a real baseline always has one) rather than
        // `ctx.count` — the count is a session tally, not a collection size.
        if let ctx = resolved.sportContext, ctx.avgDurationSec > 0 {
            HLCard(style: .elevated) {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    Text("workout.sportContext.title \(ctx.count)")
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                    HStack(spacing: HLSpace.lg) {
                        if let dur = WorkoutFormatter.duration(ctx.avgDurationSec) {
                            sportContextStat(labelKey: "Duration", value: dur)
                        }
                        if let dist = ctx.avgDistanceM, dist > 0 {
                            sportContextStat(
                                labelKey: "Distance",
                                value: WorkoutFormatter.distanceLabel(metres: dist)
                            )
                        }
                        if let hr = ctx.avgAvgHr, hr > 0 {
                            sportContextStat(labelKey: "Ø Puls", value: "\(Int(hr.rounded())) bpm")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sportContextStat(labelKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            Text(labelKey)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Text(value)
                .font(.hlSubhead.weight(.semibold).monospacedDigit())
                .foregroundStyle(HLText.primary)
        }
    }
}
