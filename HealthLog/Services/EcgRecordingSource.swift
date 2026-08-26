import Foundation

/// One ECG recording's **metadata**, platform-free.
///
/// Deliberately carries no waveform. The list of pending recordings is fetched
/// in one go (it is a handful of rows — an ECG happens a few times a year), and
/// each trace is pulled separately, one at a time, right before it is uploaded
/// and dropped right after (see ``EcgSyncCoordinator``). ~15 000 `Int`s is
/// ~120 KB of Swift array per recording; holding a year of them at once would
/// be both wasteful and a needless residency for decrypted health data.
public struct EcgSourceRecording: Sendable, Equatable, Identifiable {
    /// `HKSample.uuid.uuidString` — the identity sent as `externalRecordingId`.
    public let id: String
    /// When the device recorded the strip.
    public let recordedAt: Date
    /// Sampling rate in Hz.
    public let samplingFrequency: Double
    /// Device-reported average heart rate, if the device reported one.
    public let averageHeartRate: Double?
    /// The device's own verdict, already narrowed to the three values an ECG
    /// row may carry. `nil` when the device reported none, or reported one this
    /// route does not accept.
    public let classification: EcgIngestClassification?
    /// The lead the strip was taken on.
    public let lead: String
    /// How many voltage readings the recording holds — known from metadata, so
    /// an over-long recording is recognised **before** its trace is read.
    public let sampleCount: Int

    public init(
        id: String,
        recordedAt: Date,
        samplingFrequency: Double,
        averageHeartRate: Double?,
        classification: EcgIngestClassification?,
        lead: String,
        sampleCount: Int
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.samplingFrequency = samplingFrequency
        self.averageHeartRate = averageHeartRate
        self.classification = classification
        self.lead = lead
        self.sampleCount = sampleCount
    }
}

/// One anchored fetch: the recordings that appeared since `anchor`, plus the
/// new anchor to persist once they have been dealt with.
public struct EcgSourceFetchResult: Sendable, Equatable {
    public let recordings: [EcgSourceRecording]
    /// Opaque, archived query anchor. The coordinator persists it verbatim and
    /// never inspects it, so the seam stays free of HealthKit types.
    public let anchor: Data?

    public init(recordings: [EcgSourceRecording], anchor: Data?) {
        self.recordings = recordings
        self.anchor = anchor
    }
}

/// The HealthKit dependency of the ECG upload path, expressed as a protocol so
/// the coordinator can be driven with synthetic recordings in tests — over a
/// real ``APIClient`` + `MockURLProtocol`, never a real HealthKit store and
/// never a real health sample (PROJECT_GUIDE.md test doctrine).
///
/// The two calls are separate on purpose: metadata first, one trace at a time
/// afterwards. That split is what keeps memory bounded and is why the fetch
/// result carries `sampleCount` — an over-long recording is refused before its
/// waveform is ever materialised.
public protocol EcgRecordingSource: Sendable {
    /// Recordings that arrived since the given anchor (`nil` = everything).
    ///
    /// Anchored rather than date-windowed: HealthKit's anchor is
    /// **insertion-ordered**, so a strip recorded last week but only synced
    /// from the watch today still shows up as new — which is exactly the
    /// late-arriving case a `recordedAt` cursor would miss.
    func fetchRecordings(since anchor: Data?) async throws -> EcgSourceFetchResult

    /// The trace for ONE recording, in **volts**, index-ordered.
    ///
    /// Volts, not microvolts: the conversion is a single tested function
    /// (``EcgSampleScale``) rather than an assumption spread across the
    /// platform boundary.
    func voltages(forRecordingID id: String) async throws -> [Double]
}
