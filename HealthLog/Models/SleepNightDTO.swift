import Foundation

/// Wire shape of `GET /api/sleep/night?date=YYYY-MM-DD` (#124, server LIVE).
///
/// A per-night reconstructed sleep object: the **main** night plus zero or more
/// daytime **naps**, each a ``SleepSession`` carrying ordered hypnogram
/// ``SleepSession/segments`` plus the summary roll-ups the detail screen leads
/// with. `main` is `null` when there is no sleep data for the requested night —
/// callers render a clean empty state.
///
/// **Time handling:** every `start`/`end` is UTC ISO8601 with a trailing `Z`;
/// the decoder is ``JSONDecoder/hlDefault`` (`iso8601WithFractionalOrDayKey`),
/// so the instants decode correctly regardless of fractional seconds. The view
/// converts them to the user's CURRENT local timezone for axis labels + band
/// positioning — the DTO stores raw instants only, no timezone opinion.
///
/// **Tolerant decode:** `stages` is PARTIAL (a key may be absent) and decodes
/// into a `[SleepStage: Int]` keyed by the wire enum — unknown stage keys are
/// dropped rather than throwing, so a future server stage never breaks the read.
public struct SleepNightDTO: Codable, Sendable, Equatable {
    /// The main night. `null` ⇒ no sleep data for this date → empty state.
    public let main: SleepSession?
    /// Zero or more daytime naps, same `Session` shape as ``main``. Surfaced as
    /// a secondary section — never merged into the main band track.
    public let naps: [SleepSession]

    private enum CodingKeys: String, CodingKey {
        case main, naps
    }

    public init(main: SleepSession?, naps: [SleepSession]) {
        self.main = main
        self.naps = naps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        main = try c.decodeIfPresent(SleepSession.self, forKey: .main)
        // `naps` may be omitted entirely on a no-nap night — decode to [].
        naps = try c.decodeIfPresent([SleepSession].self, forKey: .naps) ?? []
    }
}

/// Envelope wrapper — the server nests the night under a top-level `data` key
/// (HealthLog API convention). Decoded by ``SleepNightRepository``.
public struct SleepNightEnvelope: Decodable, Sendable {
    public let data: SleepNightDTO
}

/// One reconstructed sleep session — the main night OR a single nap. Carries the
/// summary roll-ups the detail header shows + the ordered hypnogram segments.
public struct SleepSession: Codable, Sendable, Equatable {
    /// The date key this session belongs to (`YYYY-MM-DD`, parsed midnight UTC).
    public let night: Date
    /// Free-form source string, e.g. `"APPLE_HEALTH"`.
    public let source: String?
    /// Session start instant (UTC). Convert to local tz for display.
    public let start: Date
    /// Session end instant (UTC).
    public let end: Date
    public let asleepMinutes: Int?
    public let inBedMinutes: Int?
    public let awakeMinutes: Int?
    /// Number of awakenings the server counted across the night.
    public let awakenings: Int?
    /// Per-stage minutes — PARTIAL (a stage key may be absent). Unknown wire
    /// keys are dropped on decode rather than throwing.
    public let stages: [SleepStage: Int]
    /// Ordered spans that make up the hypnogram bands.
    public let segments: [SleepSegment]
    /// W-B189 (server 1.17.1) — `true` ONLY when the server SYNTHESISED an
    /// ordered timeline from a WHOOP-summary night (no real onsets exist).
    /// Measured sources (Apple Health, Withings, Fitbit, Oura) carry `false`.
    /// Tolerant decode: ABSENT on older servers (≤ 1.16.x) → defaults `false`,
    /// and the view falls back to the ``SleepHypnogramLayout/isSummaryShaped``
    /// heuristic to detect those legacy summary nights. The server flag is
    /// authoritative whenever present.
    public let reconstructed: Bool
    /// Parity Build 4 · 4.7 — set when two writer buckets reported clearly
    /// DIFFERENT asleep totals for this same session. Purely observational:
    /// the server still serves one canonical set of totals above (it picks a
    /// winner off the user's source ladder), and this field says so out loud
    /// instead of letting the app present a contested number as settled.
    /// `nil` on the ordinary path — one source, or a spread inside tolerance.
    public let sourceDiscrepancy: SleepSourceDiscrepancy?

    private enum CodingKeys: String, CodingKey {
        case night, source, start, end
        case asleepMinutes, inBedMinutes, awakeMinutes, awakenings
        case stages, segments, reconstructed, sourceDiscrepancy
    }

    public init(
        night: Date,
        source: String?,
        start: Date,
        end: Date,
        asleepMinutes: Int?,
        inBedMinutes: Int?,
        awakeMinutes: Int?,
        awakenings: Int?,
        stages: [SleepStage: Int],
        segments: [SleepSegment],
        reconstructed: Bool = false,
        sourceDiscrepancy: SleepSourceDiscrepancy? = nil
    ) {
        self.night = night
        self.source = source
        self.start = start
        self.end = end
        self.asleepMinutes = asleepMinutes
        self.inBedMinutes = inBedMinutes
        self.awakeMinutes = awakeMinutes
        self.awakenings = awakenings
        self.stages = stages
        self.segments = segments
        self.reconstructed = reconstructed
        self.sourceDiscrepancy = sourceDiscrepancy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        night = try c.decode(Date.self, forKey: .night)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        // W-SLEEP (v0.14.8) — the live route serialises every summary minute
        // field UNROUNDED (`route.ts` only rounds `segments[].minutes`): the
        // iOS uploader sends `duration / 60.0` Doubles and the server sums
        // those floats straight into `asleepMinutes` / `inBedMinutes` /
        // `awakeMinutes` / `stages`. Decoding them as `Int` threw
        // ("433.4999… is not representable") on essentially every REAL night —
        // the hypnogram never rendered. Decode as Double, round at the edge.
        asleepMinutes = try Self.roundedMinutes(c, .asleepMinutes)
        inBedMinutes = try Self.roundedMinutes(c, .inBedMinutes)
        awakeMinutes = try Self.roundedMinutes(c, .awakeMinutes)
        awakenings = try Self.roundedMinutes(c, .awakenings)
        // Tolerant stage map: decode the raw [String: Double] (fractional on
        // the live wire) then keep only the keys that map onto a known
        // `SleepStage`. A future server stage is dropped rather than throwing.
        let rawStages = try c.decodeIfPresent([String: Double].self, forKey: .stages) ?? [:]
        stages = rawStages.reduce(into: [:]) { mapped, entry in
            // `Int(safeServer:)` (W-CRASHGUARD): a non-finite / out-of-range
            // minute value drops just that stage key instead of trapping the
            // whole decode.
            if let stage = SleepStage(rawValue: entry.key), let minutes = Int(safeServer: entry.value) {
                mapped[stage] = minutes
            }
        }
        // Lossy segment list: a malformed span or an UNKNOWN future stage drops
        // that one segment instead of throwing the whole night away.
        let lossy = try c.decodeIfPresent([LossySegment].self, forKey: .segments) ?? []
        segments = lossy.compactMap(\.segment)
        // W-B189 — tolerant: absent on older servers → false (measured/legacy;
        // the view's `isSummaryShaped` heuristic still catches legacy WHOOP).
        reconstructed = try c.decodeIfPresent(Bool.self, forKey: .reconstructed) ?? false
        // Additive + lossy: absent on older servers, `null` on the ordinary
        // one-source night, and a malformed annotation degrades to "no
        // disagreement to report" rather than throwing the night away.
        sourceDiscrepancy = try? c.decodeIfPresent(
            SleepSourceDiscrepancy.self,
            forKey: .sourceDiscrepancy
        )
    }

    /// Decodes an optionally-fractional minute count and rounds it to `Int` —
    /// the wire value is a float sum of per-segment Doubles.
    private static func roundedMinutes(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Int? {
        // `Int(safeServer:)` (W-CRASHGUARD): a non-finite / out-of-range server
        // float becomes an ABSENT minute count (`nil`) rather than trapping the
        // decode. `flatMap` collapses "present-but-unrepresentable" to `nil`.
        try c.decodeIfPresent(Double.self, forKey: key).flatMap { Int(safeServer: $0) }
    }

    /// Wrapper that swallows a single segment's decode failure (unknown future
    /// stage string, malformed span) so the surrounding night still decodes.
    private struct LossySegment: Decodable {
        let segment: SleepSegment?
        init(from decoder: Decoder) {
            segment = try? SleepSegment(from: decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(night, forKey: .night)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(asleepMinutes, forKey: .asleepMinutes)
        try c.encodeIfPresent(inBedMinutes, forKey: .inBedMinutes)
        try c.encodeIfPresent(awakeMinutes, forKey: .awakeMinutes)
        try c.encodeIfPresent(awakenings, forKey: .awakenings)
        let rawStages = Dictionary(uniqueKeysWithValues: stages.map { ($0.key.rawValue, $0.value) })
        try c.encode(rawStages, forKey: .stages)
        try c.encode(segments, forKey: .segments)
        try c.encode(reconstructed, forKey: .reconstructed)
        try c.encodeIfPresent(sourceDiscrepancy, forKey: .sourceDiscrepancy)
    }
}

/// Two writer buckets disagreed about how long this session's sleep lasted.
///
/// The server dedups multi-source nights by picking ONE canonical writer off
/// the user's source ladder, which is the right call for a single number — but
/// it means a night where the phone said 6 h and the strap said 7 h 20 m looks
/// exactly like a night where everything agreed. This annotation is the
/// server saying so; the hypnogram surfaces it verbatim rather than quietly
/// presenting the winner as the whole truth.
///
/// Observational only — it never changes the served totals.
public struct SleepSourceDiscrepancy: Codable, Sendable, Equatable {
    /// max − min asleep minutes across the disagreeing buckets.
    public let deltaMinutes: Int
    /// Every writer bucket carrying an asleep total, most minutes first
    /// (server order preserved — iOS does not re-rank the sources).
    public let sources: [Bucket]

    /// One writer bucket: a `(source, deviceType)` pair and its own claim.
    public struct Bucket: Codable, Sendable, Equatable, Identifiable {
        /// Stable `ForEach` identity — a bucket key is unique within a night.
        public var id: String {
            "\(source)-\(deviceType ?? "")"
        }

        /// Wire `MeasurementSource` (e.g. `"APPLE_HEALTH"`, `"WHOOP"`).
        public let source: String
        /// Optional device refinement the server split the bucket on.
        public let deviceType: String?
        /// This bucket's own asleep total for the session.
        public let asleepMinutes: Int

        private enum CodingKeys: String, CodingKey {
            case source, deviceType, asleepMinutes
        }

        public init(source: String, deviceType: String?, asleepMinutes: Int) {
            self.source = source
            self.deviceType = deviceType
            self.asleepMinutes = asleepMinutes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            deviceType = try c.decodeIfPresent(String.self, forKey: .deviceType)
            asleepMinutes = try SleepRhythmDecoding.minutes(c, .asleepMinutes) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(source, forKey: .source)
            try c.encodeIfPresent(deviceType, forKey: .deviceType)
            try c.encode(asleepMinutes, forKey: .asleepMinutes)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case deltaMinutes, sources
    }

    public init(deltaMinutes: Int, sources: [Bucket]) {
        self.deltaMinutes = deltaMinutes
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deltaMinutes = try SleepRhythmDecoding.minutes(c, .deltaMinutes) ?? 0
        sources = try c.decodeIfPresent([Bucket].self, forKey: .sources) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deltaMinutes, forKey: .deltaMinutes)
        try c.encode(sources, forKey: .sources)
    }
}

/// One ordered hypnogram span — a contiguous run of a single ``SleepStage``.
public struct SleepSegment: Codable, Sendable, Equatable, Identifiable {
    /// Stable identity for `ForEach` — derived from the start instant + stage so
    /// it survives re-decodes without a server-supplied id.
    public var id: String {
        "\(stage.rawValue)-\(start.timeIntervalSince1970)"
    }

    public let stage: SleepStage
    public let start: Date
    public let end: Date
    public let minutes: Int?

    private enum CodingKeys: String, CodingKey {
        case stage, start, end, minutes
    }

    public init(stage: SleepStage, start: Date, end: Date, minutes: Int?) {
        self.stage = stage
        self.start = start
        self.end = end
        self.minutes = minutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // W-SLEEP (v0.14.8) — tolerant stage decode. A stage-less legacy /
        // manual row reconstructs to `stage: null` on the wire; the server
        // treats stage-less rows as the night's bare ASLEEP signal
        // (`asleepMinutesOf` fallback), so render them as the coarse ASLEEP
        // band. An UNKNOWN future stage string still throws here — the
        // session-level `LossySegment` wrapper drops just that segment.
        if let raw = try c.decodeIfPresent(String.self, forKey: .stage) {
            guard let parsed = SleepStage(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .stage,
                    in: c,
                    debugDescription: "Unknown sleep stage: \(raw)"
                )
            }
            stage = parsed
        } else {
            stage = .asleep
        }
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        // Rounded server-side today, but tolerate a fractional value.
        // `Int(safeServer:)` (W-CRASHGUARD): a non-finite / out-of-range value
        // becomes an absent minute count rather than trapping the decode.
        minutes = try c.decodeIfPresent(Double.self, forKey: .minutes).flatMap { Int(safeServer: $0) }
    }
}

/// The sleep-stage vocabulary the server emits.
///
/// `ASLEEP` is the coarse "asleep, stage unknown" bucket — distinct from the
/// finer `REM`/`CORE`/`DEEP` breakdown. ``depthRank`` orders these from
/// shallow (`AWAKE`) to deep (`DEEP`); it drives the hypnogram's vertical lane
/// position (DEEP at the bottom, Apple-Health convention) and the
/// deep→shallow ordering of the distribution band. The per-phase HUE is a
/// fixed muted-pastel CATEGORY color (W-SLEEPHYP) carried by the view layer
/// (`SleepHypnogramScreen.color(for:)`), not by depth — the four phases must be
/// distinguishable at a glance, which a lightness-only ramp did not deliver.
public enum SleepStage: String, Codable, Sendable, CaseIterable {
    case inBed = "IN_BED"
    case awake = "AWAKE"
    case asleep = "ASLEEP"
    case rem = "REM"
    case core = "CORE"
    case deep = "DEEP"

    /// Depth ordering — 0 = shallowest (awake), higher = deeper sleep. Drives
    /// the hypnogram's vertical lane (so DEEP sits at the bottom of the track,
    /// Apple Health convention) and the deep→shallow ordering of the
    /// distribution band. The phase HUE is a separate category color.
    public var depthRank: Int {
        switch self {
        case .awake: 0
        case .inBed: 1
        case .asleep: 2
        case .rem: 3
        case .core: 4
        case .deep: 5
        }
    }

    /// Localized display label for the legend + summary rows.
    public var displayKey: LocalizedStringResource {
        switch self {
        case .inBed: "sleep.stage.inBed"
        case .awake: "sleep.stage.awake"
        case .asleep: "sleep.stage.asleep"
        case .rem: "sleep.stage.rem"
        case .core: "sleep.stage.core"
        case .deep: "sleep.stage.deep"
        }
    }
}
