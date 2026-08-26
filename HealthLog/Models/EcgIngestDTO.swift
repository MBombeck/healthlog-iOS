import Foundation

/// Wire-form of the ECG **ingest** route (`POST /api/insights/ecg`, server
/// v1.35.3, GH #74).
///
/// **One recording per request, no batch.** 30 s at 512 Hz is ~15 360 samples
/// (~80 KB of JSON); the server sized the contract around exactly that, and the
/// coordinator holds one waveform at a time (see ``EcgSyncCoordinator``).
///
/// **The body is `.strict()`.** An unknown field does not fall on the floor —
/// it costs the whole recording with a 422 naming the field. Every property
/// here is one the server declared; nothing is added "for later", and
/// `sampleCount` / `durationSeconds` are deliberately absent because the server
/// derives them itself.
///
/// **`Idempotency-Key` is not evaluated on this route** and is therefore not
/// set (see ``EcgRepository/uploadRecording(_:)``). The recording carries its
/// own identity: `externalRecordingId` is the stable `HKSample.uuid`, and the
/// server holds a second unique index on
/// `(userId, source, recordedAt, samplingFrequency)` so the same physical strip
/// cannot land twice regardless of which door it came through (archive import
/// or live sync). A replay is structurally the same row, which is stronger than
/// a cached response.
public struct EcgIngestRequestDTO: Encodable, Sendable, Equatable {
    /// `HKSample.uuid.uuidString` — explicitly admitted by the server as the
    /// external identity. The archive importer's content hash is **not**
    /// reproduced here; see the type doc for why that collision is solved in
    /// the database instead of in two hash functions.
    public let externalRecordingId: String
    /// When the device recorded the strip.
    public let recordedAt: Date
    /// Sampling rate in Hz, verbatim from the recording.
    public let samplingFrequency: Double
    /// The trace in **integer microvolts**, index-ordered. Produced by exactly
    /// one function, ``EcgSampleScale/microvolts(fromVolts:)``.
    public let samples: [Int]
    /// The lead the strip was taken on.
    public let lead: String
    /// The device-reported average heart rate across the strip.
    ///
    /// Encoded with `encodeIfPresent`: HealthKit models this as optional and we
    /// will not invent a heart rate the device never reported. A recording that
    /// genuinely has none is sent without the field; should the server insist
    /// on it, the refusal is a 422 and lands in the terminal (never-retried)
    /// class like any other body rejection.
    public let averageHeartRate: Double?
    /// The recording device's own verdict, or `nil`. **Three values only** —
    /// see ``EcgIngestClassification``.
    public let classification: EcgIngestClassification?
    /// The only source a client may claim on this route. A fixed literal, not a
    /// shared enum: `WITHINGS` / `WHOOP` / `COMPUTED` are server-derived and
    /// are rejected here by construction as well as server-side.
    public let source: String

    /// The one accepted `source` value on this route.
    public static let appleHealthSource = "APPLE_HEALTH"

    /// Hard server limits (v1.35.3). Exceeding either is **not** something the
    /// client may paper over — see ``EcgSyncSkipReason/tooManySamples``.
    public static let maxSamples = 32768
    /// Body ceiling in bytes.
    public static let maxBodyBytes = 2 * 1024 * 1024

    public init(
        externalRecordingId: String,
        recordedAt: Date,
        samplingFrequency: Double,
        samples: [Int],
        lead: String,
        averageHeartRate: Double?,
        classification: EcgIngestClassification?
    ) {
        self.externalRecordingId = externalRecordingId
        self.recordedAt = recordedAt
        self.samplingFrequency = samplingFrequency
        self.samples = samples
        self.lead = lead
        self.averageHeartRate = averageHeartRate
        self.classification = classification
        source = Self.appleHealthSource
    }

    private enum CodingKeys: String, CodingKey {
        case externalRecordingId, recordedAt, samplingFrequency, samples, lead
        case averageHeartRate, classification, source
    }

    /// Hand-written so `averageHeartRate` and `classification` are OMITTED when
    /// absent rather than encoded as `null`, and so no future stored property
    /// can silently join the wire body — under `.strict()` an accidental field
    /// costs the whole recording.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(externalRecordingId, forKey: .externalRecordingId)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(samplingFrequency, forKey: .samplingFrequency)
        try container.encode(samples, forKey: .samples)
        try container.encode(lead, forKey: .lead)
        try container.encodeIfPresent(averageHeartRate, forKey: .averageHeartRate)
        try container.encodeIfPresent(classification, forKey: .classification)
        try container.encode(source, forKey: .source)
    }
}

/// The three verdicts an **ECG row** may carry, and only those.
///
/// **Deliberately NOT ``EcgClassification``, and deliberately not shared with
/// the rhythm-events surface.** The server's Prisma `RhythmClassification`
/// enum has six members because walking-steadiness severities and the neutral
/// "the device raised this notification" marker share the column; those three
/// can appear on `GET /api/insights/rhythm-events` but never on an ECG row.
/// Generating one enum from the ECG schema and reusing it on both surfaces is
/// exactly the drift raised in GH #75, and the server team named it explicitly
/// when it published this route. Two cases, two types — the read side keeps its
/// six-value ``EcgClassification`` because it must render whatever arrives; the
/// write side may only ever emit these three.
public enum EcgIngestClassification: String, Encodable, Sendable, Equatable, CaseIterable {
    case irregular = "IRREGULAR"
    case notDetected = "NOT_DETECTED"
    case inconclusive = "INCONCLUSIVE"
}

/// The route's answer: `{ id, status, recordedAt, sampleCount, durationSeconds }`.
public struct EcgIngestResponseDTO: Decodable, Sendable, Equatable {
    /// The server row id — the existing row's id in the `duplicate` case.
    public let id: String
    /// `inserted` (201) / `updated` (200) / `duplicate` (200).
    public let status: EcgIngestStatus
    public let recordedAt: Date?
    /// Server-derived — the client never sends it.
    public let sampleCount: Int?
    /// Server-derived — the client never sends it.
    public let durationSeconds: Double?

    public init(
        id: String,
        status: EcgIngestStatus,
        recordedAt: Date? = nil,
        sampleCount: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.status = status
        self.recordedAt = recordedAt
        self.sampleCount = sampleCount
        self.durationSeconds = durationSeconds
    }
}

/// What the server did with the recording. **All three are success** — that is
/// the load-bearing fact of this type.
///
/// `duplicate` in particular is the idempotent no-op the server promised: the
/// strip already exists under the archive import's content identity, nothing
/// was written, and `id` names the row that is already there. Treating it as a
/// failure would make a re-sync after an archive import look broken when it is
/// precisely the guarantee working.
public enum EcgIngestStatus: String, Decodable, Sendable, Equatable, CaseIterable {
    case inserted
    case updated
    case duplicate
}

/// The **one** place volts become microvolts.
///
/// HealthKit hands the trace out in volts; the route wants integer microvolts
/// (the same unit the server's archive CSV parser produces, so both doors agree
/// on the numbers). This is the most dangerous arithmetic in the ECG path, so
/// it lives in exactly one pure function with exactly one test suite
/// (`EcgSampleScaleTests`) rather than inline at the HealthKit boundary.
///
/// Deliberately not delegated to `HKUnit.voltUnit(with: .micro)`: keeping the
/// scale factor here makes it a value the tests can pin against known
/// physiological figures, and keeps the platform seam handing out one unit
/// (volts) instead of two.
public enum EcgSampleScale {
    /// µV per V.
    public static let microvoltsPerVolt: Double = 1_000_000

    /// Convert one voltage reading to integer microvolts.
    ///
    /// Rounds half **away from zero** so a positive and a negative reading of
    /// the same magnitude round symmetrically — banker's rounding would bias
    /// the trace's baseline by a fraction of a microvolt in one direction.
    ///
    /// - Returns: `nil` for a non-finite reading, or one whose magnitude cannot
    ///   be represented as an `Int`. A `nil` is never substituted with a zero
    ///   or a clamp: both would be a *fabricated measurement*, and the caller
    ///   drops the whole recording instead (``EcgSyncSkipReason/unreadableSample``).
    public static func microvolts(fromVolts volts: Double) -> Int? {
        guard volts.isFinite else { return nil }
        let scaled = (volts * microvoltsPerVolt).rounded(.toNearestOrAwayFromZero)
        guard scaled >= Double(Int.min), scaled <= Double(Int.max) else { return nil }
        return Int(scaled)
    }

    /// Convert a whole trace. Returns `nil` if **any** reading is unreadable —
    /// a partial waveform is a different measurement than the one the device
    /// made, so there is no honest way to send it.
    public static func microvolts(fromVolts volts: [Double]) -> [Int]? {
        var out = [Int]()
        out.reserveCapacity(volts.count)
        for value in volts {
            guard let microvolt = microvolts(fromVolts: value) else { return nil }
            out.append(microvolt)
        }
        return out
    }
}
