import Foundation

/// **W-THRESHOLD-NUDGE — per-breach debounce so a standing out-of-range value
/// does not nudge on every reading.**
///
/// Keyed on the `(kind, breach-direction)` debounce key
/// (`ThresholdNudgeEvaluator.debounceKey`). Once a breach has nudged, the same
/// standing breach is held for ``cooldown`` (default 24h). A reading that
/// returns IN-RANGE clears the key, so the *next* genuine breach can nudge again
/// (a chronic value nudges once, not endlessly; a recovered-then-relapsed value
/// nudges again).
///
/// **Storage tier — UserDefaults (device-local).** A small map of
/// `key → last-nudge timestamp`. It holds the breach key (a biomarker id or a
/// lowercased analyte name) — no values, no PHI beyond what the user already
/// sees on the labs surface; mirrors the device-local UI-pref tier. Pruned on
/// every write so it cannot grow unbounded.
enum ThresholdNudgeDebounceStore {
    /// UserDefaults key for the debounce map.
    static let mapKey = "hl.threshold.outOfRangeNudge.debounce.v1"

    /// Default cool-down: a standing breach nudges at most once per 24h.
    static let cooldown: TimeInterval = 24 * 60 * 60

    /// `true` when `key` nudged within `cooldown` of `now` — i.e. this standing
    /// breach should be debounced (no re-nudge).
    static func isDebounced(
        key: String,
        now: Date = .now,
        cooldown: TimeInterval = cooldown,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let map = load(defaults: defaults)
        guard let last = map[key] else { return false }
        return now.timeIntervalSince(last) < cooldown
    }

    /// Record that `key` just nudged (stamps `now`). Prunes entries older than
    /// `cooldown` so the map stays small.
    static func recordNudge(
        key: String,
        now: Date = .now,
        cooldown: TimeInterval = cooldown,
        defaults: UserDefaults = .standard
    ) {
        var map = load(defaults: defaults)
        map[key] = now
        prune(&map, now: now, cooldown: cooldown)
        save(map, defaults: defaults)
    }

    /// Clear the debounce for a breach key — called when a reading returns
    /// in-range, so a future relapse can nudge again.
    static func clear(key: String, defaults: UserDefaults = .standard) {
        var map = load(defaults: defaults)
        guard map.removeValue(forKey: key) != nil else { return }
        save(map, defaults: defaults)
    }

    /// Drop everything (logout wipe).
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: mapKey)
    }

    // MARK: - Private (persistence)

    private static func load(defaults: UserDefaults) -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: mapKey) as? [String: Double] else { return [:] }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func save(_ map: [String: Date], defaults: UserDefaults) {
        if map.isEmpty {
            defaults.removeObject(forKey: mapKey)
            return
        }
        let raw = map.mapValues(\.timeIntervalSince1970)
        defaults.set(raw, forKey: mapKey)
    }

    private static func prune(_ map: inout [String: Date], now: Date, cooldown: TimeInterval) {
        map = map.filter { now.timeIntervalSince($0.value) < cooldown }
    }
}
