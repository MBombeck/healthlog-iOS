import Foundation

/// Wire-form mirror of the two ECG reads (server v1.28.50):
/// `GET /api/insights/ecg` (metadata list) and `GET /api/insights/ecg/[id]`
/// (one recording WITH its decrypted, decimated waveform).
///
/// **Regulatory framing (load-bearing — do NOT soften).** Every recording here
/// was captured AND classified by the user's own recording device (today a
/// Withings ScanWatch), whose on-device algorithm is the certified one.
/// ``EcgRecordingDTO/classification`` is that device's verdict, surfaced
/// VERBATIM and always attributed to the device. HealthLog never
/// re-classifies, never reads the waveform to form an opinion, never measures
/// intervals or annotates beats, and never produces a diagnosis — it shows the
/// recording and the device's own result, paired with a permanent,
/// non-dismissible disclaimer. Same posture as ``RhythmEventsDTO``, and the
/// server route documents the identical contract.
///
/// **Data-availability gate.** An account with no recordings returns
/// `{ recordings: [], hasRecordings: false }`; the whole ECG surface un-mounts
/// (no pill, no page) rather than painting an empty box.
///
/// **Server-derived (paired only).** Both reads are pure server work — no
/// on-device fallback — so the surface hides in standalone / no-server.
public struct EcgListDTO: Codable, Sendable, Equatable {
    public let recordings: [EcgRecordingDTO]
    /// The server's own data gate (`recordings.length > 0`). The client mirrors
    /// it rather than re-deriving, so both sides agree on "there is nothing".
    public let hasRecordings: Bool

    public init(recordings: [EcgRecordingDTO], hasRecordings: Bool) {
        self.recordings = recordings
        self.hasRecordings = hasRecordings
    }

    /// The most recent recording (the list arrives `recordedAt desc`).
    public var latest: EcgRecordingDTO? {
        recordings.first
    }
}

/// One ECG recording's METADATA. Never carries a waveform — the list route
/// omits `waveformEncrypted` from its `select` by construction, so this path
/// performs no decryption at all.
public struct EcgRecordingDTO: Codable, Sendable, Equatable, Identifiable {
    /// Server row id — the detail route's path component and the list id.
    public let id: String
    /// When the device recorded the strip (ISO 8601).
    public let recordedAt: Date
    /// Strip length in seconds, when the device reported one.
    public let durationSeconds: Double?
    /// Sampling rate in Hz.
    public let samplingFrequency: Double?
    /// Number of stored samples. `0` for a `ts-`fallback event row (a verdict
    /// with no signal behind it).
    public let sampleCount: Int
    /// Device-reported average heart rate across the strip.
    public let averageHeartRate: Double?
    /// The lead the strip was taken on (e.g. `"I"`).
    public let lead: String?
    /// **The RECORDING DEVICE's own verdict, verbatim.** One of the six Prisma
    /// `RhythmClassification` values (see ``EcgClassification``) or `nil`.
    /// Decoded as a raw string with a typed accessor so a future device literal
    /// shows as itself instead of costing the row.
    public let classification: String?
    /// Ingest source (`WITHINGS`, …).
    public let source: String?
    /// `sampleCount > 0` — whether a strip exists to open at all. A row without
    /// a waveform is shown but is NOT tappable (no dead navigation).
    public let hasWaveform: Bool

    public init(
        id: String,
        recordedAt: Date,
        durationSeconds: Double?,
        samplingFrequency: Double?,
        sampleCount: Int,
        averageHeartRate: Double?,
        lead: String?,
        classification: String?,
        source: String?,
        hasWaveform: Bool
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.samplingFrequency = samplingFrequency
        self.sampleCount = sampleCount
        self.averageHeartRate = averageHeartRate
        self.lead = lead
        self.classification = classification
        self.source = source
        self.hasWaveform = hasWaveform
    }

    /// The typed device verdict.
    public var verdict: EcgClassification {
        EcgClassification(raw: classification)
    }
}

/// The device's verdict, typed. `unknown` carries the raw literal so an
/// unrecognised value is still displayed truthfully rather than dropped.
///
/// **CU-16 (A6) — the enum is `RhythmClassification`, and Prisma has SIX
/// values**, not the three the ECG OpenAPI publishes: `IRREGULAR`,
/// `NOT_DETECTED`, `INCONCLUSIVE`, `LOW`, `VERY_LOW`, `FIRED`.
/// `GET /api/insights/rhythm-events` hands all six through unfiltered, and the
/// column is shared with the ECG rows, so an ECG payload can carry any of them.
/// The last three are the EVENT-shaped verdicts (walking-steadiness severity
/// and the bare "the device raised this notification" marker) — they say
/// nothing about a rhythm strip, which is precisely why they are typed
/// separately rather than folded into the three cardiac ones.
public enum EcgClassification: Sendable, Equatable {
    case irregular
    case notDetected
    case inconclusive
    /// Prisma `LOW` — a severity level on an EVENT row (walking steadiness),
    /// never a statement about a heart rhythm.
    case low
    /// Prisma `VERY_LOW` — the more severe level of the same EVENT scale.
    case veryLow
    /// Prisma `FIRED` — "the device raised this notification"; it carries no
    /// finding at all beyond the event's own existence.
    case fired
    case none
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "IRREGULAR": self = .irregular
        case "NOT_DETECTED": self = .notDetected
        case "INCONCLUSIVE": self = .inconclusive
        case "LOW": self = .low
        case "VERY_LOW": self = .veryLow
        case "FIRED": self = .fired
        case let value?: self = .unknown(value)
        case nil: self = .none
        }
    }

    /// `true` when the DEVICE reported something other than a clean result.
    ///
    /// Drives the "discuss this with a clinician" note — and ONLY that note.
    /// It is a routing decision about the device's own verdict, never a
    /// HealthLog assessment of the trace (web `ecg-section.tsx:78-80`).
    ///
    /// **CU-16 — why `low` / `veryLow` / `fired` do NOT route here.** Those
    /// three are EVENT verdicts leaking through the shared Prisma enum; none of
    /// them is a cardiac finding on the recording being shown. Escalating a
    /// walking-steadiness severity to "discuss this ECG with a clinician" would
    /// be HealthLog inventing a cardiac finding the device never made — exactly
    /// the assertion this surface exists to avoid. Silence claims nothing; a
    /// wrong escalation claims something false. Same reasoning as `unknown`.
    public var isNonNormalDeviceResult: Bool {
        switch self {
        case .irregular, .inconclusive: true
        case .notDetected, .low, .veryLow, .fired, .none, .unknown: false
        }
    }
}

/// One recording WITH its waveform (`GET /api/insights/ecg/[id]`).
///
/// ``samples`` are microvolts, already min/max-decimated server-side to ~2500
/// display points (the R-wave peaks survive the reduction). The x position is
/// the sample INDEX — the payload carries no per-sample timestamps, and iOS
/// must not invent any. Never cached: the route answers `no-store` and this is
/// decrypted health data.
public struct EcgDetailDTO: Codable, Sendable, Equatable {
    public let recordedAt: Date
    public let durationSeconds: Double?
    public let samplingFrequency: Double?
    public let averageHeartRate: Double?
    public let lead: String?
    /// The recording device's verdict, verbatim (see ``EcgRecordingDTO``).
    public let classification: String?
    public let source: String?
    /// The trace, in microvolts, index-ordered.
    public let samples: [Double]
    /// `true` when the server reduced the raw strip to display points.
    public let decimated: Bool

    public init(
        recordedAt: Date,
        durationSeconds: Double?,
        samplingFrequency: Double?,
        averageHeartRate: Double?,
        lead: String?,
        classification: String?,
        source: String?,
        samples: [Double],
        decimated: Bool
    ) {
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.samplingFrequency = samplingFrequency
        self.averageHeartRate = averageHeartRate
        self.lead = lead
        self.classification = classification
        self.source = source
        self.samples = samples
        self.decimated = decimated
    }

    /// The typed device verdict.
    public var verdict: EcgClassification {
        EcgClassification(raw: classification)
    }
}
