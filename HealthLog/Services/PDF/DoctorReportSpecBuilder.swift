import Foundation

/// **Local Doctor Report — Spec Builder (T-7).**
///
/// Captures a `DoctorReportSpec` from a snapshot of read-only domain
/// data. The builder is a `MainActor`-bound type because the source
/// stores (`MeasurementsStore`, `MedicationsStore`, `MoodStore`,
/// `SettingsStore`) are themselves `@MainActor @Observable`. The
/// resulting `DoctorReportSpec` is fully `Sendable` and can be passed
/// to the renderer-actor without isolation hops.
///
/// Tests construct the builder with a *snapshot* (`Snapshot`) instead
/// of the live stores — that snapshot is the de-facto contract between
/// the read-path and the PDF, and is the unit that
/// `DoctorReportLocalSpecTests` exercises.
@MainActor
public enum DoctorReportSpecBuilder {
    /// Read-only snapshot of every store the builder needs. The view
    /// layer harvests this on the MainActor (where the stores already
    /// live) and then hands it off; from this point on, no further
    /// store access is required to render the PDF.
    public struct Snapshot: Sendable {
        public let patientName: String
        /// v0.10.0 — extended patient-identity fields harvested from the live
        /// `SettingsStore.profile`. Optional; the cover omits any that are
        /// `nil`/empty. `insuranceNumber` (KVNR) is sensitive PII — held only
        /// in-memory on the spec, never logged.
        public let fullName: String?
        public let insurerName: String?
        public let insuranceNumber: String?
        /// v0.11.0 — insurer IKNR (9-digit). Feeds the FHIR Coverage payor.
        /// Identifying PII — never logged.
        public let insurerIkNumber: String?
        public let appVersion: String
        public let measurements: [Measurement]
        public let medications: [Medication]
        /// #115 · 1.2 — the server's per-medication adherence
        /// (`GET /api/medications/compliance`), read when the report is
        /// generated. `nil` = the server could not be asked (offline,
        /// standalone); the report then says adherence is unavailable.
        public let serverCompliance: [MedicationComplianceSummaryEntry]?
        public let moodEntries: [MoodEntry]
        /// #115 B5 — the account's glucose unit the PDF prints glucose in.
        public let glucoseUnit: GlucoseUnit
        /// #115 P2 — the account's unit system + weight unit the PDF prints in.
        public let accountUnits: UnitPreferences

        public init(
            patientName: String,
            fullName: String? = nil,
            insurerName: String? = nil,
            insuranceNumber: String? = nil,
            insurerIkNumber: String? = nil,
            appVersion: String,
            measurements: [Measurement],
            medications: [Medication],
            serverCompliance: [MedicationComplianceSummaryEntry]? = nil,
            moodEntries: [MoodEntry],
            glucoseUnit: GlucoseUnit = .mgdL,
            accountUnits: UnitPreferences = .standard
        ) {
            self.accountUnits = accountUnits
            self.patientName = patientName
            self.fullName = fullName
            self.insurerName = insurerName
            self.insuranceNumber = insuranceNumber
            self.insurerIkNumber = insurerIkNumber
            self.appVersion = appVersion
            self.measurements = measurements
            self.medications = medications
            self.serverCompliance = serverCompliance
            self.moodEntries = moodEntries
            self.glucoseUnit = glucoseUnit
        }
    }

    /// Builds the full `DoctorReportSpec` for the given window + locale
    /// + section selection. Sections that the user toggled off come out
    /// `nil`; sections that the user toggled on but for which the
    /// snapshot has zero in-window data also come out `nil` — the
    /// renderer skips those pages entirely (empty-data handling).
    public static func build(
        snapshot: Snapshot,
        periodStart: Date,
        periodEnd: Date,
        generatedAt: Date = .now,
        selection: DoctorReportSectionSelection = .all,
        locale: ReportLocale = .de,
        calendar: Calendar = .current
    ) -> DoctorReportSpec {
        let cover = DoctorReportSpec.Cover(
            patientName: snapshot.patientName,
            fullName: snapshot.fullName?.trimmedNonEmptyOrNil,
            insurerName: snapshot.insurerName?.trimmedNonEmptyOrNil,
            insuranceNumber: snapshot.insuranceNumber?.trimmedNonEmptyOrNil,
            insurerIkNumber: snapshot.insurerIkNumber?.trimmedNonEmptyOrNil,
            periodStart: periodStart,
            periodEnd: periodEnd,
            generatedAt: generatedAt,
            appVersion: snapshot.appVersion,
            locale: locale
        )

        let measurementsInWindow = snapshot.measurements.filter {
            $0.recordedAt >= periodStart && $0.recordedAt <= periodEnd
        }
        let moodInWindow = snapshot.moodEntries.filter {
            $0.recordedAt >= periodStart && $0.recordedAt <= periodEnd
        }

        let vitals = selection.vitals
            ? makeVitalsSummary(measurements: measurementsInWindow)
            : nil
        let charts = selection.charts
            ? makeCharts(measurements: measurementsInWindow)
            : nil
        let medications = selection.medications
            ? makeMedicationsBlock(medications: snapshot.medications)
            : nil
        let adherence = selection.adherence
            ? makeAdherenceBlock(
                medications: snapshot.medications,
                serverCompliance: snapshot.serverCompliance,
                periodDays: calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: periodStart),
                    to: calendar.startOfDay(for: periodEnd)
                ).day ?? 0
            )
            : nil
        let mood = selection.mood
            ? makeMoodBlock(entries: moodInWindow)
            : nil

        let footer = DoctorReportSpec.Footer(
            disclaimer: DoctorReportDisclaimer.text(for: locale)
        )

        return DoctorReportSpec(
            cover: cover,
            vitals: vitals,
            charts: charts,
            medications: medications,
            adherence: adherence,
            mood: mood,
            footer: footer,
            glucoseUnit: snapshot.glucoseUnit,
            accountUnits: snapshot.accountUnits
        )
    }

    // MARK: - Vitals summary

    /// Mean/median/min/max per metric kind, only for kinds with ≥ 1 in-window
    /// sample. Blood-pressure carries `secondaryMean` for the diastolic
    /// component; every other metric leaves it `nil`.
    static func makeVitalsSummary(measurements: [Measurement]) -> DoctorReportSpec.VitalsSummary? {
        let grouped: [MetricKind: [Measurement]] = Dictionary(grouping: measurements, by: \.kind)
        guard !grouped.isEmpty else { return nil }

        let rows: [DoctorReportSpec.VitalsSummary.Row] = MetricKind.allCases.compactMap { kind in
            // Audit B-4 — `.unknown` is a bucket, not a kind: two rows on it may
            // carry two different server types this build cannot name, so a
            // mean/median/min/max across them is a figure about nothing. It has
            // no business in the one export a clinician reads.
            guard !kind.isUnknown else { return nil }
            guard let bucket = grouped[kind], !bucket.isEmpty else { return nil }
            let primaries = bucket.map(\.primaryValue)
            let mean = primaries.reduce(0, +) / Double(primaries.count)
            let median = Self.median(of: primaries)
            let min = primaries.min() ?? 0
            let max = primaries.max() ?? 0
            let secondaryMean: Double? = kind == .bloodPressure
                ? Self.diastolicMean(of: bucket)
                : nil
            return DoctorReportSpec.VitalsSummary.Row(
                kind: kind,
                mean: mean,
                median: median,
                min: min,
                max: max,
                count: bucket.count,
                secondaryMean: secondaryMean
            )
        }
        return rows.isEmpty ? nil : DoctorReportSpec.VitalsSummary(rows: rows)
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    static func diastolicMean(of measurements: [Measurement]) -> Double? {
        let diastolics: [Double] = measurements.compactMap { measurement in
            if case let .bloodPressure(_, diastolic) = measurement.value {
                return diastolic
            }
            return nil
        }
        guard !diastolics.isEmpty else { return nil }
        return diastolics.reduce(0, +) / Double(diastolics.count)
    }

    // MARK: - Charts

    static func makeCharts(measurements: [Measurement]) -> DoctorReportSpec.ChartsBlock? {
        let grouped: [MetricKind: [Measurement]] = Dictionary(grouping: measurements, by: \.kind)
        guard !grouped.isEmpty else { return nil }
        let series: [DoctorReportSpec.ChartsBlock.Series] = MetricKind.allCases.compactMap { kind in
            // Audit B-4 — same reason as the vitals summary: an axis implies a
            // shared unit and scale the sentinel cannot promise.
            guard !kind.isUnknown else { return nil }
            guard let bucket = grouped[kind], !bucket.isEmpty else { return nil }
            let sorted = bucket.sorted { $0.recordedAt < $1.recordedAt }
            let points = sorted.map { measurement -> DoctorReportSpec.ChartsBlock.Point in
                switch measurement.value {
                case let .scalar(value):
                    DoctorReportSpec.ChartsBlock.Point(at: measurement.recordedAt, value: value)
                case let .bloodPressure(systolic, diastolic):
                    DoctorReportSpec.ChartsBlock.Point(
                        at: measurement.recordedAt,
                        value: systolic,
                        secondary: diastolic
                    )
                }
            }
            return DoctorReportSpec.ChartsBlock.Series(kind: kind, points: points)
        }
        return series.isEmpty ? nil : DoctorReportSpec.ChartsBlock(series: series)
    }

    // MARK: - Medications

    /// Active + archived medications split. Each row collapses the
    /// `Medication.schedule.times` list into a human-readable string
    /// like "08:00, 20:00" — the doctor reads the schedule as a glance,
    /// not as a recurrence-rule.
    static func makeMedicationsBlock(medications: [Medication]) -> DoctorReportSpec.MedicationsBlock? {
        guard !medications.isEmpty else { return nil }
        let active = medications.filter(\.active).map(makeRow(_:))
        let archived = medications.filter { !$0.active }.map(makeRow(_:))
        if active.isEmpty, archived.isEmpty {
            return nil
        }
        return DoctorReportSpec.MedicationsBlock(active: active, archived: archived)
    }

    private static func makeRow(_ med: Medication) -> DoctorReportSpec.MedicationsBlock.Row {
        let times = med.schedule.times
            .map { time in String(format: "%02d:%02d", time.hour, time.minute) }
            .joined(separator: ", ")
        let schedule = times.isEmpty ? "—" : times
        return DoctorReportSpec.MedicationsBlock.Row(
            id: med.id,
            name: med.name,
            dose: med.dose,
            treatmentClass: med.treatmentClass,
            schedule: schedule
        )
    }

    // MARK: - Adherence

    /// #115 · 1.2 — one row per active, scheduled (non-PRN) medication with
    /// the server's `compliance30` verbatim. Returns `nil` when there is no
    /// active medication to report on. With no server answer the block is
    /// `.unavailable` and carries no rows — the drawer says so.
    static func makeAdherenceBlock(
        medications: [Medication],
        serverCompliance: [MedicationComplianceSummaryEntry]?,
        periodDays: Int
    ) -> DoctorReportSpec.AdherenceBlock? {
        let active = medications.filter(\.active)
        guard !active.isEmpty else { return nil }
        let windowDays = 30
        guard let serverCompliance else {
            return DoctorReportSpec.AdherenceBlock(
                availability: .unavailable, windowDays: windowDays, periodDays: periodDays, perMedication: []
            )
        }
        let byID = Dictionary(serverCompliance.map { ($0.medicationId, $0) }, uniquingKeysWith: { first, _ in first })
        // PRN medications carry no server entry (the route excludes them), so
        // they get no row rather than an invented one.
        let rows: [DoctorReportSpec.AdherenceBlock.Row] = active.compactMap { med in
            guard let entry = byID[med.id] else { return nil }
            guard entry.isApplicable else {
                return .init(
                    medicationId: med.id, medicationName: med.name, applicable: false,
                    rate: nil, taken: nil, expected: nil
                )
            }
            let window = entry.compliance30
            return .init(
                medicationId: med.id, medicationName: med.name, applicable: true,
                rate: window.rate, taken: window.taken, expected: window.taken + window.missed
            )
        }
        guard !rows.isEmpty else { return nil }
        return DoctorReportSpec.AdherenceBlock(
            availability: .server, windowDays: windowDays, periodDays: periodDays, perMedication: rows
        )
    }

    // MARK: - Mood

    /// Sparkline samples (score over time) + the three most common tags
    /// in the window. Skips entirely when the window has no entries.
    static func makeMoodBlock(entries: [MoodEntry]) -> DoctorReportSpec.MoodBlock? {
        // **Audit B-4 — the clinician's export plots scores and states an
        // average.** An entry whose level this build cannot name has neither, so
        // it is not a point on the sparkline and not a term in the mean. A
        // window holding nothing but such entries has no mood block at all —
        // which is the one honest thing to hand a doctor.
        guard !entries.isEmpty else { return nil }
        let scored = MoodEntry.scored(entries).sorted { $0.entry.recordedAt < $1.entry.recordedAt }
        guard !scored.isEmpty else { return nil }
        let sparkline = scored.map { DoctorReportSpec.MoodBlock.Point(at: $0.entry.recordedAt, score: $0.score) }
        let total: Int = sparkline.reduce(0) { $0 + $1.score }
        let avg = Double(total) / Double(sparkline.count)
        let tagCounts: [String: Int] = scored
            .flatMap(\.entry.tags)
            .reduce(into: [String: Int]()) { counts, tag in
                counts[tag, default: 0] += 1
            }
        let dominant = tagCounts
            .map { DoctorReportSpec.MoodBlock.TagCount(tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag < rhs.tag
            }
            .prefix(3)
        return DoctorReportSpec.MoodBlock(
            sparkline: sparkline,
            dominantTags: Array(dominant),
            averageScore: avg,
            count: sparkline.count
        )
    }
}

// MARK: - String helper

private extension String {
    /// Trimmed value, or `nil` when empty after trimming. Used so the cover
    /// + FHIR Patient omit a blank identity line entirely rather than
    /// rendering "Krankenkasse: ".
    var trimmedNonEmptyOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
