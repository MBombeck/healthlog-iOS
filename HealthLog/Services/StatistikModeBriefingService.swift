import Foundation

/// Local "Statistik-Mode" briefing builder — the FLOOR for "Heute auf einen
/// Blick" on the Dashboard + Insights surfaces.
///
/// **Why this exists (v0.5.4 BF-1):** the on-device path needs Apple
/// Intelligence + iOS 26; the server-AI path needs a provider configured
/// against the user account. When BOTH are unavailable (third-attempt
/// operator-reported failure of the hero), the hero historically resolved
/// to `.empty` and the operator read it as "keine Daten".
///
/// This service composes a `DailyBriefing` from the data the iOS app
/// already has locally:
/// 1. Recent measurements (7d/30d totals, top-3 active kinds, latest
///    value per kind, simple direction arrow comparing the latest reading
///    against the rolling mean of the window).
/// 2. Medication compliance for today (taken/scheduled ratio).
/// 3. Last mood entry + 7-day average score.
///
/// The output is shaped as `DailyBriefing` so it slots into the existing
/// `DailyBriefingHero` renderer without view-side changes — `paragraph` +
/// `keyFindings` chips. Renderable regardless of feature-flag state, since
/// it never transmits data anywhere.
///
/// Stay strictly observational — never predict, prescribe, diagnose.
/// Numbers come from operator data only, never invented.
public enum StatistikModeBriefingService {
    /// Public entry. Returns `nil` only when every input bucket is empty
    /// (no measurements, no mood entries in the last 7 days, no compliance
    /// snapshot for today). Callers route `nil` → `.empty` for the hero.
    public static func compose(
        measurements: [Measurement],
        moodEntries: [MoodEntry],
        compliance: ComplianceSnapshotInput?,
        healthScore: HealthScore?,
        locale _: Locale = .current,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> DailyBriefing? {
        let recentMeasurements = measurements.filter {
            now.timeIntervalSince($0.recordedAt) <= 7 * 86400
        }
        let recentMood = moodEntries.filter {
            now.timeIntervalSince($0.recordedAt) <= 7 * 86400
        }

        let hasMeasurements = !recentMeasurements.isEmpty
        let hasMood = !recentMood.isEmpty
        let hasCompliance = (compliance?.scheduledToday ?? 0) > 0
            || (compliance?.takenToday ?? 0) > 0
        let hasHealthScore = healthScore != nil

        guard hasMeasurements || hasMood || hasCompliance || hasHealthScore else {
            return nil
        }

        let paragraph = buildParagraph(
            measurements: recentMeasurements,
            moodEntries: recentMood,
            compliance: compliance,
            now: now,
            calendar: calendar
        )

        var findings: [KeyFinding] = []

        // Top-3 most-active kinds, with latest value + direction arrow vs
        // 7-day mean. The arrow is intentionally simple: "↑" if latest is
        // > mean + 5%, "↓" if < mean - 5%, "→" otherwise. We are not
        // predicting — only describing the last sample relative to the
        // surrounding week.
        let perKind = perKindBuckets(measurements: recentMeasurements)
        let topKinds = perKind
            .sorted { $0.samples > $1.samples }
            .prefix(3)
        for bucket in topKinds {
            findings.append(measurementFinding(bucket: bucket))
        }

        // Compliance finding when meds are scheduled today.
        if let compliance, compliance.scheduledToday > 0 {
            findings.append(complianceFinding(compliance: compliance))
        }

        // Mood finding when the operator logged at least one entry in
        // the last 7 days.
        if let moodFinding = moodFinding(entries: recentMood) {
            findings.append(moodFinding)
        }

        // HealthScore finding when the server delivered one.
        if let healthScore {
            findings.append(healthScoreFinding(score: healthScore))
        }

        // Hero compact-style only renders the first two chips, but the
        // full-style scrolls all of them. Cap at 6 to keep the
        // accessibility-VoiceOver experience sane and the prompt for
        // any downstream on-device summariser well below 4096 tokens.
        let cappedFindings = Array(findings.prefix(6))

        return DailyBriefing(paragraph: paragraph, keyFindings: cappedFindings)
    }

    // MARK: - Paragraph composition

    private static func buildParagraph(
        measurements: [Measurement],
        moodEntries: [MoodEntry],
        compliance: ComplianceSnapshotInput?,
        now: Date,
        calendar: Calendar
    ) -> String {
        let date = now.formatted(
            Date.FormatStyle(date: .long, time: .omitted, locale: Locale.current)
        )
        var pieces: [String] = [headline(date: date)]

        if !measurements.isEmpty {
            let topKindName = topKindLabel(measurements: measurements)
            pieces.append(
                String(localized: "briefing.measurements \(measurements.count) \(topKindName)")
            )
        } else {
            pieces.append(String(localized: "briefing.measurements.none"))
        }

        if let compliance, compliance.scheduledToday > 0 {
            let pct = Int(((Double(compliance.takenToday) / Double(compliance.scheduledToday)) * 100).rounded())
            pieces.append(
                String(
                    localized: "briefing.compliance.line \(compliance.takenToday) \(compliance.scheduledToday) \(pct)"
                )
            )
        }

        if let latestMood = moodEntries.max(by: { $0.recordedAt < $1.recordedAt }) {
            let avg = moodEntries.map { Double($0.score) }.reduce(0, +) / Double(moodEntries.count)
            let avgStr = String(format: "%.1f", avg)
            let isToday = calendar.isDateInToday(latestMood.recordedAt)
            let prefix = isToday
                ? String(localized: "briefing.mood.today")
                : String(localized: "briefing.mood.latest")
            pieces.append(
                String(localized: "briefing.mood.line \(prefix) \(latestMood.score) \(avgStr)")
            )
        }

        return pieces.joined(separator: " ")
    }

    private static func headline(date: String) -> String {
        String(localized: "briefing.today \(date)")
    }

    private static func topKindLabel(measurements: [Measurement]) -> String {
        var counts: [MetricKind: Int] = [:]
        for m in measurements {
            counts[m.kind, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else {
            return "—"
        }
        return top.displayName
    }

    // MARK: - KeyFinding builders

    struct KindBucket {
        let kind: MetricKind
        let samples: Int
        let latest: Measurement?
        let mean: Double?
    }

    private static func perKindBuckets(measurements: [Measurement]) -> [KindBucket] {
        var buckets: [MetricKind: [Measurement]] = [:]
        for m in measurements {
            buckets[m.kind, default: []].append(m)
        }
        return buckets.map { kind, rows in
            let scalars: [Double] = rows.map(\.primaryValue)
            let mean: Double? = scalars.isEmpty ? nil : scalars.reduce(0, +) / Double(scalars.count)
            return KindBucket(
                kind: kind,
                samples: rows.count,
                latest: rows.max(by: { $0.recordedAt < $1.recordedAt }),
                mean: mean
            )
        }
    }

    private static func measurementFinding(bucket: KindBucket) -> KeyFinding {
        let label = bucket.kind.displayName
        let latestValue = bucket.latest.flatMap { formatValue(measurement: $0, kind: bucket.kind) }
        let directionArrow = arrow(for: bucket)
        let headline = "\(label) · \(bucket.samples)×"
        let detail: String = if let latestValue {
            directionArrow.map { "\($0) \(latestValue)" } ?? latestValue
        } else {
            String(localized: "briefing.entries \(bucket.samples)")
        }
        return KeyFinding(
            tone: .info,
            headline: headline,
            detail: detail,
            delta: directionArrow,
            sourceWindow: "7d",
            sourceMetric: kindSourceKey(bucket.kind)
        )
    }

    private static func complianceFinding(compliance: ComplianceSnapshotInput) -> KeyFinding {
        let pct = Int(((Double(compliance.takenToday) / Double(compliance.scheduledToday)) * 100).rounded())
        let headline = String(localized: "briefing.compliance.headline \(pct)")
        let detail = String(localized: "briefing.compliance.detail \(compliance.takenToday) \(compliance.scheduledToday)")
        return KeyFinding(
            tone: pct >= 80 ? .good : .info,
            headline: headline,
            detail: detail,
            delta: nil,
            sourceWindow: "1d",
            sourceMetric: "compliance"
        )
    }

    private static func moodFinding(entries: [MoodEntry]) -> KeyFinding? {
        guard let latest = entries.max(by: { $0.recordedAt < $1.recordedAt }) else { return nil }
        let avg = entries.map { Double($0.score) }.reduce(0, +) / Double(entries.count)
        let avgStr = String(format: "%.1f", avg)
        let headline = String(localized: "briefing.mood.headline \(latest.score)")
        let detail = String(localized: "briefing.mood.detail \(avgStr)")
        return KeyFinding(
            tone: .info,
            headline: headline,
            detail: detail,
            delta: nil,
            sourceWindow: "7d",
            sourceMetric: "mood"
        )
    }

    private static func healthScoreFinding(score: HealthScore) -> KeyFinding {
        let headline = String(localized: "briefing.healthscore.headline \(score.score)")
        let detail: String
        if let delta = score.delta {
            let sign = delta >= 0 ? "+" : ""
            let deltaText = "\(sign)\(delta)"
            detail = String(localized: "briefing.healthscore.delta \(deltaText)")
        } else {
            detail = String(localized: "briefing.healthscore.weekly")
        }
        return KeyFinding(
            tone: .info,
            headline: headline,
            detail: detail,
            delta: nil,
            sourceWindow: "7d",
            sourceMetric: ""
        )
    }

    // MARK: - Helpers

    /// Direction arrow comparing latest reading against the rolling mean
    /// of the 7-day window. Returns `nil` for blood-pressure (two-value
    /// payload — direction is not meaningful as a single arrow on a 1D
    /// chart) and for buckets that have only one sample (no mean to
    /// compare against).
    private static func arrow(for bucket: KindBucket) -> String? {
        guard let latest = bucket.latest else { return nil }
        guard bucket.kind != .bloodPressure else { return nil }
        guard bucket.samples > 1, let mean = bucket.mean else { return nil }
        let latestScalar = latest.primaryValue
        let threshold = max(0.001, mean * 0.05)
        if latestScalar > mean + threshold {
            return "↑"
        }
        if latestScalar < mean - threshold {
            return "↓"
        }
        return "→"
    }

    /// Per-kind value formatter. BP renders "sys/dia mmHg", scalars render
    /// with kind-appropriate precision. Reused from the previous
    /// curated-digest format for visual continuity.
    private static func formatValue(measurement: Measurement, kind: MetricKind) -> String? {
        switch measurement.value {
        case let .scalar(v):
            let formatted = switch kind {
            case .pulse, .restingHeartRate, .spo2, .glucose, .steps:
                String(format: "%.0f", v)
            default:
                String(format: "%.1f", v)
            }
            let unit = kind.unit
            return unit.isEmpty ? formatted : "\(formatted) \(unit)"
        case let .bloodPressure(systolic, diastolic):
            return String(format: "%.0f/%.0f %@", systolic, diastolic, kind.unit)
        }
    }

    /// Snapshot-key used by `DailyBriefingHero`'s `metricLabel` lookup so
    /// the per-chip footer renders the localised metric name from the
    /// existing mapping table rather than duplicating it here. Table-
    /// driven so the cyclomatic-complexity ceiling stays satisfied as new
    /// MetricKind cases land.
    private static let sourceKeys: [MetricKind: String] = [
        .bloodPressure: "bp",
        .weight: "weight",
        .pulse: "pulse",
        .bmi: "bmi",
        .hrv: "hrv",
        .sleep: "sleep",
        .restingHeartRate: "resting_hr",
        .steps: "steps",
        .vo2Max: "vo2_max",
        .bodyTemperature: "body_temp",
        .glucose: "glucose",
        .bodyFat: "body_fat",
        .spo2: "spo2",
        .bodyWater: "body_water",
        .boneMass: "bone_mass",
        .walkingSpeed: "walking_speed",
        .walkingAsymmetry: "walking_asymmetry",
        .walkingStepLength: "walking_step_length"
    ]

    private static func kindSourceKey(_ kind: MetricKind) -> String {
        sourceKeys[kind] ?? kind.rawValue
    }
}

/// Minimal compliance input the service consumes. Mirrors the relevant
/// half of `ComplianceSnapshot` so callers don't need to depend on the
/// dashboard model when they only have today's compliance numbers from
/// MedicationsStore.
public struct ComplianceSnapshotInput: Sendable, Equatable {
    public let takenToday: Int
    public let scheduledToday: Int

    public init(takenToday: Int, scheduledToday: Int) {
        self.takenToday = takenToday
        self.scheduledToday = scheduledToday
    }

    /// Adaptor for the dashboard-summary shape so the dashboard surface
    /// can hand the snapshot through unchanged.
    public init(from snapshot: ComplianceSnapshot) {
        takenToday = snapshot.takenToday
        scheduledToday = snapshot.scheduledToday
    }
}
