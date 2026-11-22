import Foundation

// What the capture sheet knows about the person's own habits for the chosen
// kind, as the web's add form does (`use-measurement-entry-assist.ts`): the
// kinds they log by hand, their last reading of this kind, whether the typed
// value is far from it, and the meal context a new glucose reading starts on.
// Pure functions over rows the store already holds, so every rule has a test.

/// When a typed reading is far enough from the person's own last one to ask
/// "is that right?". A hint, never a block: the sane range in
/// ``MeasurementRanges`` is what refuses a value.
///
/// The thresholds are the web's, one to one
/// (`src/lib/measurements/last-value-deviation.ts:29-46` on server
/// `release/v1.49.0`), compared in the stored canonical unit. A kind that is
/// not listed gets no hint (glucose, pain, HRV and the rest move by large
/// amounts from one reading to the next as a matter of course).
enum MeasureLastValueDeviation {
    enum Threshold: Equatable {
        /// The change, as a share of the last value, exceeds this.
        case relative(Double)
        /// The change, in the canonical unit, exceeds this.
        case absolute(Double)
    }

    /// `last-value-deviation.ts:29-46`.
    static let thresholds: [MetricKind: Threshold] = [
        .weight: .relative(0.1),
        .bodyWater: .relative(0.15),
        .boneMass: .relative(0.15),
        .fatMass: .relative(0.15),
        .fatFreeMass: .relative(0.15),
        .leanBodyMass: .relative(0.15),
        .muscleMass: .relative(0.15),
        .bodyFat: .absolute(8),
        .pulse: .relative(0.5),
        .restingHeartRate: .relative(0.3),
        .spo2: .absolute(6),
        .bodyTemperature: .absolute(1.5),
        .waistCircumference: .relative(0.1),
        .gripStrength: .relative(0.3)
    ]

    /// `BLOOD_PRESSURE_SYS` and `BLOOD_PRESSURE_DIA`, each on its own.
    static let bloodPressure: Threshold = .relative(0.3)

    /// `deviatesFromLast` (`last-value-deviation.ts:49-61`).
    static func deviates(_ value: Double, from last: Double?, threshold: Threshold?) -> Bool {
        guard let threshold, let last, value.isFinite, last.isFinite else { return false }
        let delta = abs(value - last)
        switch threshold {
        case let .absolute(limit):
            return delta > limit
        case let .relative(share):
            guard last != 0 else { return false }
            return delta / abs(last) > share
        }
    }

    /// A scalar typed for `kind` (already canonical) against the last reading.
    static func deviates(kind: MetricKind, canonical value: Double?, last: Measurement?) -> Bool {
        guard let value, let last, case let .scalar(lastValue) = last.value else { return false }
        return deviates(value, from: lastValue, threshold: thresholds[kind])
    }

    /// A blood pressure pair: either leg far from its own last leg. A leg not
    /// typed yet says nothing.
    static func deviates(systolic: Double?, diastolic: Double?, last: Measurement?) -> Bool {
        guard let last, case let .bloodPressure(lastSystolic, lastDiastolic) = last.value else { return false }
        let systolicOff = systolic.map { deviates($0, from: lastSystolic, threshold: bloodPressure) } ?? false
        let diastolicOff = diastolic.map { deviates($0, from: lastDiastolic, threshold: bloodPressure) } ?? false
        return systolicOff || diastolicOff
    }
}

/// The person's last reading of a kind, as the line under the value field
/// quotes it ("Zuletzt 72,4 kg, heute").
enum MeasureLastValue {
    /// Kinds whose "last reading" is not one reading: a night of sleep stages,
    /// a day of step chunks. The web gives them no line either
    /// (`use-measurement-entry-assist.ts:22-25`).
    static let withoutLine: Set<MetricKind> = [.sleep, .steps]

    /// The newest reading of `kind` in `rows` (newest first, any source: a
    /// scale that syncs is still "my last weight").
    static func reading(of kind: MetricKind, in rows: [Measurement]) -> Measurement? {
        guard !withoutLine.contains(kind) else { return nil }
        return rows.first { $0.kind == kind && !$0.id.hasPrefix("local-") }
    }
}

/// The kinds a person logs by hand, most recent first, from their own manual
/// readings (`src/lib/measurements/recent-entry-types.ts:27-71`), so a
/// morning weight and blood pressure routine lands on the same kinds on every
/// device.
enum MeasureRecentEntryKinds {
    /// Manual rows the web reads for this (`use-entry-recall.ts:12`).
    static let manualRowWindow = 60
    /// How many kinds the rows offer (`recentEntryTypes`' default).
    static let maximum = 3

    /// The distinct kinds in `rows` (newest first), limited to `offered`. A
    /// pulse taken at the instant of a blood pressure reading is part of that
    /// reading, as on the web; one typed alone stays a pulse.
    static func kinds(from rows: [Measurement], offered: [MetricKind], maximum: Int = maximum) -> [MetricKind] {
        let manual = rows.filter { $0.source == .manual }.prefix(manualRowWindow)
        let bloodPressureInstants = Set(manual.filter { $0.kind == .bloodPressure }.map(\.recordedAt))
        var seen: [MetricKind] = []
        for row in manual {
            let kind: MetricKind = row.kind == .pulse && bloodPressureInstants.contains(row.recordedAt)
                ? .bloodPressure
                : row.kind
            guard offered.contains(kind), !seen.contains(kind) else { continue }
            seen.append(kind)
            if seen.count >= maximum { break }
        }
        return seen
    }

    /// The kind "Save and next" moves on to: the most recent other kind, or
    /// `nil` when there is none (`nextUsualType`, `recent-entry-types.ts:66-71`).
    static func next(after current: MetricKind, recent: [MetricKind]) -> MetricKind? {
        recent.first { $0 != current }
    }
}

/// The meal context a new glucose reading starts on
/// (`src/lib/measurements/glucose-context-default.ts:27-51`). The person's own
/// habit wins: the most recent reading with a context taken within 90 minutes
/// of the same clock time on another day. Without one, the hour decides:
/// before 10:00 fasting, from then on after a meal.
enum GlucoseContextDefault {
    static let similarMinutes = 90
    static let fastingUntilHour = 10
    /// Glucose readings the web looks through (`use-entry-recall.ts:14`).
    static let historyWindow = 20

    static func context(at date: Date, history: [Measurement], calendar: Calendar = .current) -> GlucoseContext {
        let readings = history.filter { $0.kind == .glucose }.prefix(historyWindow)
        for reading in readings {
            guard let context = reading.glucoseContext else { continue }
            if clockDistance(reading.recordedAt, date, calendar: calendar) <= similarMinutes {
                return context
            }
        }
        return calendar.component(.hour, from: date) < fastingUntilHour ? .fasting : .afterMeal
    }

    /// Minutes between two clock times, the short way round midnight.
    static func clockDistance(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Int {
        func minutes(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let diff = abs(minutes(lhs) - minutes(rhs))
        return min(diff, 24 * 60 - diff)
    }
}

/// The value an edit field opens with: the reading in the unit and at the
/// precision its row shows ("5,6 mmol/L" edits as "5,6"), never grouped, so
/// what the person reads is what they change.
enum MeasureEditPrefill {
    static func text(_ canonical: Double, kind: MetricKind, units: UnitPreferences, locale: Locale = .current) -> String {
        let transform = units.transform(for: kind)
        let digits = transform.fractionDigits.map { $0 ... $0 } ?? 0 ... 2
        return HLValueFormat.number(transform.display(canonical), fractionDigits: digits, grouping: .never, locale: locale)
    }

    /// One blood pressure leg, as the row shows it (mmHg whole, kPa one decimal).
    static func bloodPressureText(_ canonical: Double, units: UnitPreferences, locale: Locale = .current) -> String {
        let digits = units.bloodPressure == .mmHg ? 0 ... 0 : 1 ... 1
        return HLValueFormat.number(
            units.convertBloodPressure(canonical),
            fractionDigits: digits,
            grouping: .never,
            locale: locale
        )
    }
}

/// The words of the save receipt and the last-value line.
enum MeasureEntryWording {
    /// The reading with its unit, as its row shows it ("72,4 kg", "120/80 mmHg").
    static func valueText(_ value: MeasurementValue, kind: MetricKind, units: UnitPreferences) -> String {
        let number: String = switch value {
        case let .scalar(v):
            MetricDurationFormat.text(v, kind: kind)
                ?? MetricValueFormatter.formatScalar(v, kind: kind, units: units)
        case let .bloodPressure(s, d):
            MetricValueFormatter.formatBloodPressure(systolic: s, diastolic: d, units: units)
        }
        let suffix = MetricDurationFormat.unit(MetricValueFormatter.unitSuffix(for: kind, units: units), kind: kind)
        return suffix.isEmpty ? number : "\(number) \(suffix)"
    }

    /// "Gewicht 72,4 kg gespeichert" (web `common.savedWithValue`).
    static func receipt(kind: MetricKind, value: MeasurementValue, units: UnitPreferences) -> String {
        String(localized: "measure.receipt.saved \(kind.displayName) \(valueText(value, kind: kind, units: units))")
    }

    /// "Zuletzt 72,4 kg, gestern" (web `measurements.lastValue`).
    static func lastValue(_ reading: Measurement, units: UnitPreferences, now: Date = .now) -> String {
        let value = valueText(reading.value, kind: reading.kind, units: units)
        return String(localized: "measure.lastValue \(value) \(HLDateFormat.relative(reading.recordedAt, now: now))")
    }
}
