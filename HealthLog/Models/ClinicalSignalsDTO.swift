import Foundation

// Wire-form mirrors of the three v1.25 read-only "clinical signals" awareness
// reads (server `release/v1.25.0`, GH iOS #38). All three are PURE server
// compute over existing engines — no provider call, neutral / non-diagnostic
// framing — and route through the standard `{ data, error, meta }` envelope the
// `APIClient` unwraps before decode.
//
// **Server source (read verbatim, not from a stale OpenAPI dump):**
//   - `src/lib/openapi/routes/insights-signals.ts` (the frozen response shapes)
//   - `src/lib/insights/health-status.ts` (`summariseHealthStatus`)
//   - `src/lib/insights/breathing-screening.ts` (`summariseBreathing`)
//   - `src/lib/insights/labs-changes.ts` (`summariseLabChanges`)
//
// **Server-authoritative, render-don't-recompute.** iOS DECODES and DISPLAYS
// the server's already-finished signals verbatim — it never re-derives a band,
// a shift, a trend, or a delta on-device. Each card self-suppresses when its
// payload is absent / not present, exactly like the other conditional insight
// cards (HONEST-ONLY).
//
// **Tolerant decode.** Every field is `decodeIfPresent` with a safe default so
// a partial / future-extended payload never rejects the whole read; an unknown
// enum token (a measurement type the iOS catalogue does not know, or a future
// direction value) is kept raw and the row degrades gracefully rather than
// crashing.

// MARK: - GET /api/insights/health-status → InsightsHealthStatus

/// Vitals drifting from the user's personal normal — band deviations plus dated,
/// sustained level shifts. Awareness only, never a diagnosis.
public struct InsightsHealthStatusDTO: Codable, Sendable, Equatable {
    /// `true` when at least one deviation or shift is surfaced.
    public let present: Bool
    public let deviations: [Deviation]
    public let shifts: [Shift]
    /// ISO-8601 instant the read was computed (caption only). `nil` ⇒ no chip.
    public let generatedAt: Date?

    public init(present: Bool = false, deviations: [Deviation] = [], shifts: [Shift] = [], generatedAt: Date? = nil) {
        self.present = present
        self.deviations = deviations
        self.shifts = shifts
        self.generatedAt = generatedAt
    }

    /// `true` when the card has at least one renderable row. Drives the
    /// self-suppression gate.
    public var hasContent: Bool {
        present && (!deviations.isEmpty || !shifts.isEmpty)
    }

    private enum CodingKeys: String, CodingKey {
        case present, deviations, shifts, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? false
        deviations = try c.decodeIfPresent([Deviation].self, forKey: .deviations) ?? []
        shifts = try c.decodeIfPresent([Shift].self, forKey: .shifts) ?? []
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }

    /// One vital sitting outside its personal band today.
    public struct Deviation: Codable, Sendable, Equatable, Identifiable {
        /// Server `MeasurementType` token (e.g. `"PULSE"`, `"RESTING_HEART_RATE"`).
        public let type: String
        /// Today's value.
        public let value: Double
        /// Personal band center (median).
        public let center: Double
        public let low: Double
        public let high: Double
        /// Which side of the band the value falls on — `"above"` / `"below"`.
        public let direction: String

        public var id: String {
            type
        }

        public init(type: String, value: Double, center: Double, low: Double, high: Double, direction: String) {
            self.type = type
            self.value = value
            self.center = center
            self.low = low
            self.high = high
            self.direction = direction
        }

        private enum CodingKeys: String, CodingKey {
            case type, value, center, low, high, direction
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
            center = try c.decodeIfPresent(Double.self, forKey: .center) ?? 0
            low = try c.decodeIfPresent(Double.self, forKey: .low) ?? 0
            high = try c.decodeIfPresent(Double.self, forKey: .high) ?? 0
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        }

        /// The iOS metric for this server token, or `nil` for an unknown token
        /// (which the card drops — tolerant, never a crash).
        public var metricKind: MetricKind? {
            ServerMeasurementType(rawValue: type)?.metricKind
        }

        /// `true` when the value is above the band (else below).
        public var isAbove: Bool {
            direction == "above"
        }
    }

    /// One dated, sustained level shift from the changepoint detector.
    public struct Shift: Codable, Sendable, Equatable, Identifiable {
        /// Server `MeasurementType` token.
        public let metric: String
        /// `YYYY-MM-DD` of the first day of the new level.
        public let breakDate: String
        public let beforeMean: Double
        public let afterMean: Double
        /// `"up"` / `"down"`.
        public let direction: String

        public var id: String {
            "\(metric)-\(breakDate)"
        }

        public init(metric: String, breakDate: String, beforeMean: Double, afterMean: Double, direction: String) {
            self.metric = metric
            self.breakDate = breakDate
            self.beforeMean = beforeMean
            self.afterMean = afterMean
            self.direction = direction
        }

        private enum CodingKeys: String, CodingKey {
            case metric, breakDate, beforeMean, afterMean, direction
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? ""
            breakDate = try c.decodeIfPresent(String.self, forKey: .breakDate) ?? ""
            beforeMean = try c.decodeIfPresent(Double.self, forKey: .beforeMean) ?? 0
            afterMean = try c.decodeIfPresent(Double.self, forKey: .afterMean) ?? 0
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? ""
        }

        public var metricKind: MetricKind? {
            ServerMeasurementType(rawValue: metric)?.metricKind
        }

        public var isUp: Bool {
            direction == "up"
        }
    }
}

// MARK: - GET /api/insights/breathing-screening → InsightsBreathingScreening

/// Sleep-breathing-disturbance screening signal — a screening signal only,
/// never a diagnosis.
public struct InsightsBreathingScreeningDTO: Codable, Sendable, Equatable {
    public let present: Bool
    /// Nights with a per-night index reading.
    public let nights: Int
    /// Mean of the index readings (lower-better); `nil` when none.
    public let recentMeanIndex: Double?
    /// Recent index vs the prior window — `"up"` / `"down"` / `"stable"`; `nil`
    /// when too few nights.
    public let trend: String?
    /// Device-flagged breathing-disturbance / apnea events.
    public let eventCount: Int
    /// The device's own classification — `"not-elevated"` / `"elevated"`; `nil`
    /// when no data.
    public let classification: String?
    public let generatedAt: Date?

    public init(
        present: Bool = false,
        nights: Int = 0,
        recentMeanIndex: Double? = nil,
        trend: String? = nil,
        eventCount: Int = 0,
        classification: String? = nil,
        generatedAt: Date? = nil
    ) {
        self.present = present
        self.nights = nights
        self.recentMeanIndex = recentMeanIndex
        self.trend = trend
        self.eventCount = eventCount
        self.classification = classification
        self.generatedAt = generatedAt
    }

    /// `true` when the screening read has data to surface.
    public var hasContent: Bool {
        present && (nights > 0 || eventCount > 0)
    }

    /// `true` when the device flagged one or more breathing-disturbance events.
    public var isElevated: Bool {
        classification == "elevated"
    }

    private enum CodingKeys: String, CodingKey {
        case present, nights, recentMeanIndex, trend, eventCount, classification, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? false
        nights = try c.decodeIfPresent(Int.self, forKey: .nights) ?? 0
        recentMeanIndex = try c.decodeIfPresent(Double.self, forKey: .recentMeanIndex)
        trend = try c.decodeIfPresent(String.self, forKey: .trend)
        eventCount = try c.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        classification = try c.decodeIfPresent(String.self, forKey: .classification)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }
}

// MARK: - GET /api/insights/labs-changes → InsightsLabsChanges

/// Per-analyte change between the two most-recent numeric lab panels. Neutral
/// framing, never a diagnosis.
public struct InsightsLabsChangesDTO: Codable, Sendable, Equatable {
    public let present: Bool
    /// `YYYY-MM-DD` of the most-recent panel, or `nil` when absent.
    public let latestDate: String?
    /// `YYYY-MM-DD` of the prior panel, or `nil` when absent.
    public let previousDate: String?
    public let changes: [Change]
    public let generatedAt: Date?

    public init(
        present: Bool = false,
        latestDate: String? = nil,
        previousDate: String? = nil,
        changes: [Change] = [],
        generatedAt: Date? = nil
    ) {
        self.present = present
        self.latestDate = latestDate
        self.previousDate = previousDate
        self.changes = changes
        self.generatedAt = generatedAt
    }

    /// `true` when the card has at least one analyte change to surface.
    public var hasContent: Bool {
        present && !changes.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case present, latestDate, previousDate, changes, generatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? false
        latestDate = try c.decodeIfPresent(String.self, forKey: .latestDate)
        previousDate = try c.decodeIfPresent(String.self, forKey: .previousDate)
        changes = try c.decodeIfPresent([Change].self, forKey: .changes) ?? []
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
    }

    /// One analyte's signed change between the two most-recent panels.
    public struct Change: Codable, Sendable, Equatable, Identifiable {
        public let analyte: String
        public let unit: String
        public let latest: Double
        public let previous: Double
        /// Signed `latest − previous`.
        public let delta: Double
        /// `"up"` / `"down"` / `"flat"`.
        public let direction: String
        /// Reference-band standing of the LATEST value —
        /// `"in-range"` / `"below"` / `"above"` / `"unknown"`.
        public let status: String

        public var id: String {
            analyte
        }

        public init(
            analyte: String,
            unit: String,
            latest: Double,
            previous: Double,
            delta: Double,
            direction: String,
            status: String
        ) {
            self.analyte = analyte
            self.unit = unit
            self.latest = latest
            self.previous = previous
            self.delta = delta
            self.direction = direction
            self.status = status
        }

        private enum CodingKeys: String, CodingKey {
            case analyte, unit, latest, previous, delta, direction, status
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            analyte = try c.decodeIfPresent(String.self, forKey: .analyte) ?? ""
            unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
            latest = try c.decodeIfPresent(Double.self, forKey: .latest) ?? 0
            previous = try c.decodeIfPresent(Double.self, forKey: .previous) ?? 0
            delta = try c.decodeIfPresent(Double.self, forKey: .delta) ?? 0
            direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? "flat"
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        }
    }
}
