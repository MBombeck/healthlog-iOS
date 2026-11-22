import Foundation

/// The order the symptoms are offered in, and the intensity a picked one
/// starts on, as the web's quick entry has them (`orderSymptomsByUse`,
/// `latestIntensityById` in `symptom-chip-filter.ts`).
///
/// The symptoms felt most in the last 30 days come first, the more recently
/// felt one ahead on a tie; every symptom not used in that time follows in
/// the server's own order. A picked symptom starts on the intensity it was
/// last logged with, so a recurring complaint is one tap and a glance.
enum SymptomUsage {
    /// The definitions in the order of use. Pure; the server's order is kept
    /// among the unused ones and on a full tie.
    static func orderedByUse(_ definitions: [SymptomDefinition]) -> [SymptomDefinition] {
        let indexed = Array(definitions.enumerated())
        let used = indexed
            .filter { ($0.element.recent?.count30d ?? 0) > 0 }
            .sorted { lhs, rhs in
                let lc = lhs.element.recent?.count30d ?? 0
                let rc = rhs.element.recent?.count30d ?? 0
                if lc != rc { return lc > rc }
                let lt = lhs.element.recent?.lastOccurredDate ?? .distantPast
                let rt = rhs.element.recent?.lastOccurredDate ?? .distantPast
                if lt != rt { return lt > rt }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let unused = definitions.filter { ($0.recent?.count30d ?? 0) == 0 }
        return used + unused
    }

    /// Each symptom's most recent intensity, from occurrences listed newest
    /// first (the order `GET /api/symptoms/events` answers in).
    static func latestIntensities(_ events: [SymptomEvent]) -> [String: Int] {
        var latest: [String: Int] = [:]
        for event in events where latest[event.definitionId] == nil && !event.definitionId.isEmpty {
            latest[event.definitionId] = event.intensity
        }
        return latest
    }

    /// What a pick does to the intensity: a new pick starts on the symptom's
    /// last intensity while the field is empty or still holds the previous
    /// pick's preset; an intensity the person chose stays. `presetFor` names
    /// the symptom whose last intensity the field holds, `nil` once the
    /// person chose one.
    static func afterPick(
        _ definitionId: String?,
        intensity: Int?,
        presetFor: String?,
        last: [String: Int]
    ) -> (intensity: Int?, presetFor: String?) {
        let holdsPreset = presetFor != nil
        guard let definitionId else {
            return holdsPreset ? (nil, nil) : (intensity, nil)
        }
        guard intensity == nil || holdsPreset else { return (intensity, nil) }
        if let previous = last[definitionId] {
            return (previous, definitionId)
        }
        return holdsPreset ? (nil, nil) : (intensity, nil)
    }
}
