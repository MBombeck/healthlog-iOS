import Foundation

public extension Int {
    /// Crash-safe conversion of a server-supplied `Double` to `Int`.
    ///
    /// **Why this exists (W-CRASHGUARD, AUDIT-RELIABILITY C1/C2/H1):** the
    /// stdlib `Int(_ source: Double)` initializer **traps** when its argument is
    /// non-finite (`NaN`/`±inf`) *or* finite but outside `Int.min ... Int.max`
    /// after rounding. A bad server value (`1e308`, an unsanitised `Infinity`,
    /// a `NaN` from a divide-by-zero on the server) flowing into
    /// `Int(x.rounded())` therefore crashes the app — inside a `Decodable`
    /// `init` it crashes the whole decode.
    ///
    /// This factory returns `nil` instead of trapping for any value that the
    /// stdlib initializer would reject, so callers render the em-dash
    /// placeholder (or drop the field) rather than tearing the process down.
    ///
    /// Contract:
    /// - non-finite (`NaN`, `+inf`, `-inf`) → `nil`
    /// - finite but `< Int.min` or `> Int.max` after rounding → `nil`
    /// - otherwise → the rounded `Int` (round-half-away-from-zero via `.rounded()`,
    ///   matching the `Int(x.rounded())` call sites this replaces)
    ///
    /// The bounds check uses `Double(Int.max)` / `Double(Int.min)`, which round
    /// to the nearest representable Double (`2^63` / `-2^63`); comparing with
    /// `<` / `>=` keeps every in-range value and rejects every out-of-range one
    /// without itself trapping.
    init?(safeServer value: Double) {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        // `Double(Int.max)` rounds up to 2^63 (not representable as Int), so the
        // upper bound is strict `<`; the lower bound `-2^63` IS representable as
        // `Int.min`, so it is inclusive `>=`.
        guard rounded < Double(Int.max), rounded >= Double(Int.min) else { return nil }
        self.init(rounded)
    }
}

public extension Double {
    /// The em-dash placeholder every "no value / unrepresentable value" surface
    /// renders. Hoisted so the safe-server string formatters below stay terse.
    static let emDashPlaceholder = "—"

    /// Crash-safe whole-number string of a server `Double`, applying `format`
    /// (default plain) to the rounded `Int`. Returns the em-dash placeholder for
    /// a non-finite / out-of-`Int.range` value instead of trapping `Int(...)`.
    ///
    /// Lets a presentation `switch` arm stay a single expression (no per-case
    /// `guard`), which keeps the formatter functions under the cyclomatic-
    /// complexity gate while closing the `Int(serverDouble)` trap (W-CRASHGUARD).
    func safeServerIntString(_ format: IntegerFormatStyle<Int> = .number) -> String {
        guard let whole = Int(safeServer: self) else { return Double.emDashPlaceholder }
        return whole.formatted(format)
    }

    /// Crash-safe grouped (`1,234`) whole-number string — convenience over
    /// ``safeServerIntString(_:)`` for the `groupedInteger` format style.
    var safeServerGroupedIntString: String {
        safeServerIntString(.number.grouping(.automatic))
    }

    /// Crash-safe "Xh Ym" sleep-duration string — `self` is a count of HOURS
    /// (the server emits the sleep `latestValue` in hours). Em-dash for a
    /// non-finite / out-of-`Int.range` minute product (W-CRASHGUARD).
    var safeServerSleepDurationHM: String {
        guard let rawMinutes = Int(safeServer: self * 60) else { return Double.emDashPlaceholder }
        // W-RECONCILE L-1 — clamp to 0 so a stray negative server value can never
        // render a nonsensical "-1h -30m" (server is non-negative; defensive only).
        let totalMinutes = max(0, rawMinutes)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(localized: "\(hours)h \(minutes)m", comment: "Sleep duration — hours and minutes")
    }

    /// Crash-safe `sys/dia` whole-number blood-pressure string. Returns the
    /// em-dash placeholder (the WHOLE pair, not a half-formed `—/81`) if either
    /// operand is non-finite / out-of-`Int.range` (W-CRASHGUARD).
    static func safeServerBPString(systolic: Double, diastolic: Double) -> String {
        guard let sys = Int(safeServer: systolic), let dia = Int(safeServer: diastolic) else {
            return emDashPlaceholder
        }
        return "\(sys)/\(dia)"
    }
}
