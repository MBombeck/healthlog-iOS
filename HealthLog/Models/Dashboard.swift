import Foundation

/// v0150 nav-scroll RCA (Bug 3): `Equatable` so `DashboardStore` can DEDUP a
/// summary reassignment. The SWR `.cached` → `.fresh` emit pair on every
/// foreground revalidate previously reassigned `summary` even when the value was
/// byte-identical, rebuilding the whole `if let summary` dashboard subtree (Highlight
/// card / compliance ring / metrics grid + the empty-tile policy re-eval) on every
/// return to Home → a top-of-stack height churn under the restored scroll offset,
/// felt as "springt hoch". Equality lets the store skip the no-op assignment.
public struct DashboardSummary: Codable, Sendable, Equatable {
    public let greeting: Greeting
    // v0.12 W4-5 — the `streak: StreakBadge?` field was decoded + plumbed
    // through two `DashboardStore` reducers but NEVER rendered by any view
    // (dead carry-through, consistent with the "no dashboard streak
    // gamification" decision — MEMORY: operator flagged streak counters as
    // "too much"). Dropped from the model + the construction sites. The server
    // still emits a `streak` key for the web client; the synthesized `Codable`
    // here simply IGNORES that unknown key on decode (no `CodingKeys` entry for
    // it), so the dashboard keeps decoding cleanly — removal is graceful, not a
    // decode break.
    public let compliance: ComplianceSnapshot
    public let highlightInsight: Insight?
    public let metrics: [DashboardMetric]
    /// Server liefert `lastUpdated` heute immer (`now.toISOString()`), aber wir
    /// modellieren es trotzdem optional — sobald ein Caching-Layer mal `null`
    /// zurückgibt, bricht sonst das ganze Dashboard-Decoding (W2a-A2 Audit §9.5).
    public let lastUpdated: Date?
}

public extension DashboardSummary {
    private enum CodingKeys: String, CodingKey {
        case greeting, compliance, highlightInsight, metrics, lastUpdated
    }

    /// Element-tolerant metrics decode. **#51 — the summary route now emits
    /// `mood`/`bmi` tile kinds (and may add more) that iOS does not model until
    /// Build 7.3.** `MetricKind` is a closed enum, so the non-optional per-element
    /// `kind` decode threw on an unmodelled raw value and rejected the WHOLE
    /// `metrics` array → the entire summary failed to decode ("Daten konnten nicht
    /// gelesen werden", tiles fell back to the error card). Each tile is decoded
    /// lossily and un-modellable ones are dropped, mirroring
    /// ``DashboardScoreRing/SkipUnknown``. Order is preserved for the survivors.
    /// (Memberwise init stays available because this lives in an extension.)
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            greeting: c.decode(Greeting.self, forKey: .greeting),
            compliance: c.decode(ComplianceSnapshot.self, forKey: .compliance),
            highlightInsight: c.decodeIfPresent(Insight.self, forKey: .highlightInsight),
            metrics: c.decode([DashboardMetric.SkipUnknown].self, forKey: .metrics)
                .compactMap(\.metric),
            lastUpdated: c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        )
    }
}

public extension DashboardMetric {
    /// Lossy per-element wrapper: a tile whose `kind` is outside this client's
    /// closed ``MetricKind`` set (a future server kind such as `mood`/`bmi`
    /// pre-7.3) decodes to `nil` and is dropped, so one unknown kind never throws
    /// away the whole `metrics` array.
    struct SkipUnknown: Decodable, Sendable {
        public let metric: DashboardMetric?

        public init(from decoder: Decoder) throws {
            metric = try? DashboardMetric(from: decoder)
        }
    }
}

public struct Greeting: Codable, Sendable, Equatable {
    public let salutation: String
    public let date: Date
}

public struct ComplianceSnapshot: Codable, Sendable, Equatable {
    public let scheduledToday: Int
    public let takenToday: Int

    public init(scheduledToday: Int, takenToday: Int) {
        self.scheduledToday = scheduledToday
        self.takenToday = takenToday
    }

    /// v0.5.1-A B3: when nothing is scheduled today the previous return of
    /// `1.0` (interpreted as 100%) was misleading — the ring filled to a
    /// full circle even when the operator had no meds queued at all.
    /// New contract: an empty schedule maps to `0` so renderers can detect
    /// the no-data case via `hasSchedule` and render "—" instead of "100%".
    public var ratio: Double {
        scheduledToday == 0 ? 0 : Double(takenToday) / Double(scheduledToday)
    }

    /// `true` when the server delivered at least one scheduled intake for
    /// today. Renderers use this to distinguish "nothing scheduled" from
    /// "all taken" (both produce `takenToday == scheduledToday` historically).
    public var hasSchedule: Bool {
        scheduledToday > 0
    }

    /// **Audit H2.** Fully-framed VoiceOver label for the dashboard
    /// compliance ring. The ring otherwise combines to the bare value
    /// ("4 / 6") with no context. Extracted here (over `String(localized:)`
    /// inline in the View) so the EN/DE wiring is unit-testable without a
    /// SwiftUI host.
    public var ringAccessibilityLabel: String {
        guard hasSchedule else {
            return String(localized: "Medication compliance today: nothing scheduled")
        }
        return String(
            localized: "Medication compliance today, \(takenToday) of \(scheduledToday) taken"
        )
    }

    /// **v0.5.4.3 HP-6.** Operator screenshot (build 17) showed
    /// "Medikamenten-Compliance / Heute nichts geplant" on a Dashboard
    /// where intakes were demonstrably scheduled — the (since-deleted,
    /// v0.14.8 AUDIT-HOME M6) `UpcomingMedicationsCard` rendered them right
    /// above on the same surface. Root cause: the
    /// server's `compliance.scheduledToday` aggregator uses a different
    /// window than `/api/medications/intake?scope=today` (UTC-bucketed
    /// vs. user-tz day-of), and the early-morning operator hit the
    /// window mismatch every refresh.
    ///
    /// Mitigation without a server roundtrip: synthesise a corrected
    /// snapshot from `todayIntakes` (the same payload `UpcomingMeds` is
    /// authoritative on) for any user-tz calendar-day intake whose
    /// parent medication is still `active`. We never *narrow* the
    /// server's view — only widen it when the local view sees more.
    /// If both sources see zero we keep the server snapshot so the
    /// "nothing scheduled" branch still renders for truly empty days.
    ///
    /// - Parameters:
    ///   - server: snapshot from `DashboardSummary.compliance`.
    ///   - todayIntakes: `MedicationsStore.todayIntakes` (already
    ///     server-canonical for the today scope per `route.ts:94-108`).
    ///   - activeMedicationIDs: ids of `active == true` meds — intakes
    ///     for archived meds don't count toward "planned today".
    ///   - now: clock anchor (test-injectable).
    ///   - calendar: used for `startOfDay` boundaries (test-injectable).
    /// - Parameter medicationsLoaded: `true` once `MedicationsStore` has
    ///   hydrated its medication list from cache or network
    ///   (`MedicationsStore.hasLoadedMedications`). Distinguishes a genuine COLD
    ///   START (meds not yet loaded → the local view is empty only because it has
    ///   no data → trust the server snapshot) from "loaded, legitimately 0 slots
    ///   scheduled today" (→ the empty day-anchored local view is authoritative,
    ///   so a stale non-day-anchored server count must NOT leak through). This is
    ///   the v0.14.8 INV-home-compliance-slot defence-in-depth: even if a stale
    ///   `summary.compliance` somehow reaches here (e.g. a cache row that has not
    ///   yet rolled), the reconciler prefers the empty local truth once meds are
    ///   loaded rather than rendering "2 von 2 genommen".
    /// - Returns: the snapshot a renderer should consume. When the local
    ///   user-tz view produced any slot for today (`localScheduled > 0`) the
    ///   local pair is returned verbatim — it is internally consistent
    ///   (`taken ≤ scheduled` always), tz-correct, dedup-merged, and carries
    ///   the optimistic-taken count from `markIntakeQuick`. When the local view
    ///   is empty AND meds are loaded, the empty local pair (`0/0`) is returned
    ///   so a genuinely-nothing-scheduled day renders the calm empty state rather
    ///   than a stale server count. Only on a genuine cold start
    ///   (`medicationsLoaded == false`) does it fall back to `server` so the
    ///   first-paint "nothing scheduled" / cold-cache path still renders.
    public static func reconciled(
        server: ComplianceSnapshot,
        todayIntakes: [MedicationIntake],
        activeMedicationIDs: Set<String>,
        medicationsLoaded: Bool,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ComplianceSnapshot {
        let startOfToday = calendar.startOfDay(for: now)
        guard let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return server
        }
        let dayIntakes = todayIntakes.filter { intake in
            guard activeMedicationIDs.contains(intake.medicationId) else { return false }
            return intake.scheduledAt >= startOfToday && intake.scheduledAt < endOfToday
        }
        let localScheduled = dayIntakes.count
        // **v0.14.1 DOSE-SAFETY.** A `.taken` intake whose `scheduledAt` is in
        // the FUTURE must never count toward the taken total. The server can
        // stamp a not-yet-due slot `taken` (the ±6h afternoon→19:00 explicit-
        // write snap in `resolve-slot-instant.ts`, filed server-side), and a
        // clock-skew edge could surface one too. Counting it makes
        // `taken == scheduled` → the card reads "alles eingenommen" while the
        // evening dose is still pending → the real dose gets masked. The
        // invariant "a dose due in the future cannot have been taken" is the
        // client-side dose-safety backstop. See
        // `.planning/v0148-cycle-marathon/INV-med-phantom-taken.md`.
        let localTaken = dayIntakes.filter { $0.status == .taken && $0.scheduledAt <= now }.count
        // v0.10 R5: trust the local user-tz view as the single source of
        // truth for the count. The previous per-axis `max(server, local)`
        // merge (v0.5.4.3 HP-6 / v0.8.1 WC) was unsound across the UTC/user-tz
        // seam: `max(scheduledA, scheduledB)` is not the count of any single
        // coherent day, so the server's UTC-bucketed `scheduledToday` could
        // leak a phantom extra dose (the "1 von 3" twice-daily Lisinopril bug)
        // while `taken > scheduled` invariants were never preserved. The local
        // pair is tz-correct, dedup-merged, and carries the optimistic-taken
        // count (`markIntakeQuick` patches `todayIntakes` in place), so the
        // never-narrow optimistic behaviour is preserved without `max`.
        guard localScheduled > 0 else {
            // No local slot for today. Two cases, distinguished by
            // `medicationsLoaded` (v0.14.8 INV-home-compliance-slot):
            //   • COLD START (meds not loaded): the local view is empty only
            //     because it has no data yet — keep the server snapshot so the
            //     cold-cache first-paint / "nothing scheduled" path renders.
            //   • LOADED, 0 today-slots: the empty day-anchored local view is
            //     authoritative (genuinely nothing scheduled today, or all slots
            //     are on a different day). Prefer the empty local pair (0/0) over
            //     the server count so a stale non-day-anchored
            //     `summary.compliance` can never render a phantom "2 von 2
            //     genommen" — the calm empty state shows instead.
            return medicationsLoaded
                ? ComplianceSnapshot(scheduledToday: 0, takenToday: 0)
                : server
        }
        return ComplianceSnapshot(
            scheduledToday: localScheduled,
            takenToday: localTaken
        )
    }
}

public struct DashboardMetric: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let kind: MetricKind
    /// Resolved display title. **W-SERVER-SYNC (server v1.5.5):** the server's
    /// `MetricCard` switched from a translated `title` literal to an i18n
    /// `titleKey` (e.g. `dashboard.metric.title.weight`). The decoder below is
    /// tolerant of both shapes — it prefers `titleKey` (resolved against the
    /// app's `Localizable.xcstrings` via `String(localized:)`), and falls back
    /// to a legacy `title` string when the key is absent, so neither deploy
    /// order breaks the dashboard.
    ///
    /// The two catalogue namespaces the server addresses this way are
    /// `dashboard.metric.title.` and `dashboard.metric.unit.` — they are built
    /// at runtime and never appear as literals, so `scripts/check-strings.sh`
    /// carries both as `dynamicKeyPrefixes` and anchors them on this comment
    /// (UI-Standard R18/E8).
    public let title: String
    /// Nullable im Server-Schema (`MetricCard`, src/app/api/dashboard/summary/
    /// route.ts:25-47): wenn der User noch nie eine Messung dieses Typs hatte,
    /// liefert der Server `null`. Früher non-optional → ganzes Dashboard-Decode
    /// brach beim ersten neuen User (W2a-A2 Audit §2.3).
    public let latestValue: Double?
    public let secondaryValue: Double? // BP diastolic
    /// Resolved display unit. Same tolerant `unitKey` → legacy `unit` decode
    /// path as ``title`` (server v1.5.5 sends `unitKey`).
    public let unit: String
    public let trend: TrendIndicator
    public let sparkline: [Double]
    public let updatedAt: Date?

    public init(
        id: String,
        kind: MetricKind,
        title: String,
        latestValue: Double?,
        secondaryValue: Double?,
        unit: String,
        trend: TrendIndicator,
        sparkline: [Double],
        updatedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.latestValue = latestValue
        self.secondaryValue = secondaryValue
        self.unit = unit
        self.trend = trend
        self.sparkline = sparkline
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, titleKey, latestValue, secondaryValue, unit, unitKey, trend, sparkline, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try Self.decodeKind(from: c)
        // v0.14 / v1.11.5 — SLEEP is a plain passthrough now. The dashboard
        // summary route emits sleep as the per-NIGHT TIME-ASLEEP total ALREADY
        // IN HOURS (float, e.g. 7.2) with an explicit `unit: "h"`
        // (`src/app/api/dashboard/summary/route.ts` — `latestValue: toHours(
        // night.asleepMinutes)`, `unit: "h"`, sparkline = trailing nights'
        // asleep hours). The earlier ÷60 (Task #105) assumed raw minutes and is
        // now WRONG — it would shrink a real 7.2 h night to 0.12 h. We read the
        // hours value verbatim, so the tile agrees with the list path
        // (`MeasurementDTO.sleepHours`) and the series route, which also send
        // the per-night total in the same hours unit. No ×60 re-encode hack
        // either: encode is a straight inverse, so the SWR cache round-trip is
        // the identity.
        latestValue = try c.decodeIfPresent(Double.self, forKey: .latestValue)
        secondaryValue = try c.decodeIfPresent(Double.self, forKey: .secondaryValue)
        trend = try c.decode(TrendIndicator.self, forKey: .trend)
        sparkline = try c.decodeIfPresent([Double].self, forKey: .sparkline) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        title = try Self.resolve(
            key: c.decodeIfPresent(String.self, forKey: .titleKey),
            legacy: c.decodeIfPresent(String.self, forKey: .title)
        )
        unit = try Self.resolve(
            key: c.decodeIfPresent(String.self, forKey: .unitKey),
            legacy: c.decodeIfPresent(String.self, forKey: .unit)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        // v0.14 / v1.11.5 — straight encode (no sleep ×60 re-encode hack). Since
        // `init(from:)` no longer rewrites sleep (the server sends hours
        // directly), encode is a plain inverse and the SWR cache round-trip
        // (`SWRCoordinator.observe` re-encodes then re-decodes) stays the
        // identity for every kind.
        try c.encodeIfPresent(latestValue, forKey: .latestValue)
        try c.encode(sparkline, forKey: .sparkline)
        try c.encodeIfPresent(secondaryValue, forKey: .secondaryValue)
        try c.encode(unit, forKey: .unit)
        try c.encode(trend, forKey: .trend)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// Build 7 / item 7.3 — decode `kind` with the summary route's short-token
    /// aliases bridged onto the domain `MetricKind`.
    ///
    /// The `/api/dashboard/summary` route documents `kind` as "iOS-friendly
    /// (camelCase)" and for all but one kind it equals the `MetricKind` raw value.
    /// The exception is **BMI**: the summary emits the short `"bmi"` token while
    /// the domain raw value is `"bodyMassIndex"` (the camelCase mirror of the
    /// server `MeasurementType` used by the series / snapshot paths). Without this
    /// bridge the strict per-element `MetricKind` decode threw on `"bmi"` and the
    /// tolerant `SkipUnknown` wrapper dropped the whole tile (the reported "BMI
    /// tile never renders"). We accept BOTH tokens so a summary payload AND a SWR
    /// cache round-trip (which re-encodes the raw value `"bodyMassIndex"`) decode.
    /// `mood` needs no alias — its raw value already equals the summary token.
    private static func decodeKind(from c: KeyedDecodingContainer<CodingKeys>) throws -> MetricKind {
        let raw = try c.decode(String.self, forKey: .kind)
        if let kind = MetricKind(rawValue: raw) { return kind }
        switch raw {
        case "bmi": return .bmi
        default:
            // Preserve the original strict-decode error semantics for a genuinely
            // unknown kind so the tolerant `SkipUnknown` wrapper drops just this
            // tile (never the whole array).
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "Unknown dashboard metric kind: \(raw)"
            )
        }
    }

    /// Tolerant title/unit resolution shared by both fields.
    ///
    /// 1. `key` present (server v1.5.5 `titleKey`/`unitKey`) → resolve against
    ///    the app's `Localizable.xcstrings`. In the SPM/unit-test context the
    ///    main bundle carries no catalogue, so `String(localized:)` returns the
    ///    key verbatim — that is still a stable, non-crashing value.
    /// 2. else `legacy` (pre-v1.5.5 translated `title`/`unit`) → use as-is.
    /// 3. else empty string (a brand-new metric with neither field).
    static func resolve(key: String?, legacy: String?) -> String {
        if let key, !key.isEmpty {
            return String(localized: String.LocalizationValue(key))
        }
        return legacy ?? ""
    }
}

public enum TrendIndicator: String, Codable, Sendable {
    case up
    case down
    case flat
    case unknown
}

public extension DashboardMetric {
    /// Convenience: formatierter Anzeigetext für das Dashboard. Nil-Werte
    /// werden als Em-Dash gerendert ("noch keine Daten"). BP hängt Diastolisch
    /// hinten dran, sofern vorhanden.
    var displayValue: String {
        guard let latest = latestValue, latest.isFinite else { return "—" }
        if let secondary = secondaryValue {
            // W-CRASHGUARD — `latestValue`/`secondaryValue` decode unsanitized
            // from the server (`1e400` → +inf, a server-side divide → NaN, a
            // finite `1e30` out of `Int.range`). `Int()` of any of those TRAPS
            // at runtime → dashboard crash. Route both operands through
            // `Int(safeServer:)`; a non-finite OR out-of-range tile value
            // renders the em-dash placeholder, never crashes.
            guard let sys = Int(safeServer: latest), let dia = Int(safeServer: secondary) else { return "—" }
            return "\(sys)/\(dia)"
        }
        return latest.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    /// #33 — `true` when the server-summary snapshot carries a real BP reading:
    /// both components present, finite, and `> 0`. A malformed `0/77` snapshot
    /// (a seed/validation gap the server is fixing) must NOT paint on the
    /// dashboard tile's cold-launch first frame before the guarded
    /// `MetricDataState` fan-out resolves the true latest. Meaningful only for
    /// the blood-pressure tile; non-BP metrics carry no `secondaryValue`.
    var hasDisplayableBloodPressureSnapshot: Bool {
        guard let sys = latestValue, sys.isFinite, sys > 0,
              let dia = secondaryValue, dia.isFinite, dia > 0 else { return false }
        return true
    }
}
