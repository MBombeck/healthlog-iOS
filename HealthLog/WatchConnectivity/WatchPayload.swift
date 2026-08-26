import Foundation

// MARK: - Shared WatchConnectivity contract (iPhone app ⇄ HealthLog watchOS companion)

//
// **v0.12 P2 — watchOS companion.** This file is the ONLY code shared
// between the phone app and the watch app (compiled into both via source
// membership). It is intentionally **Foundation-only** and references no
// app `Models` type, so the watch target stays thin — it never imports the
// `Medication` / `MedicationIntake` / `IntakeStatus` types, the APIClient,
// the Outbox, or any auth surface.
//
// Direction of travel:
//  - **Phone → Watch:** the phone pushes a `WatchSnapshot` via
//    `WCSession.updateApplicationContext` (latest-wins, coalesced) whenever
//    the medication schedule / today's intakes / latest mood change. The
//    watch renders it offline-safe.
//  - **Watch → Phone:** the watch sends a `WatchAction` via
//    `WCSession.transferUserInfo` (durable FIFO, survives reboot, wakes the
//    phone in background). The phone funnels it into the EXISTING
//    server-first store/Outbox pipeline — one write path, no duplication.
//
// `WatchIntakeStatus` mirrors the rawValues of the app's `IntakeStatus`
// (`taken` / `skipped` / `snoozed`) so the phone can bridge with
// `IntakeStatus(rawValue:)` without the watch importing the enum.

/// The three actionable intake transitions the watch can request. Raw
/// values are bit-identical to the app's `IntakeStatus` cases so the phone
/// bridges with `IntakeStatus(rawValue: watchStatus.rawValue)`.
public enum WatchIntakeStatus: String, Codable, Sendable, Hashable {
    case taken
    case skipped
    case snoozed
}

/// The small set of manual-entry measurements the watch can quick-capture at
/// the wrist. Raw values are bit-identical to the app's `MetricKind` cases so
/// the phone bridges with `MetricKind(rawValue: watchKind.rawValue)` without
/// the watch target importing the (large) `MetricKind` enum or any `Models`
/// type. These are deliberately the four numeric, manual-friendly kinds — a
/// single scalar (or the BP systolic/diastolic pair) the Digital Crown can
/// enter in seconds; richer kinds stay on the phone's `MeasureSheet`.
public enum WatchMeasurementKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case weight
    case bloodPressure
    case glucose
    case pulse

    public var id: String {
        rawValue
    }
}

/// The glanceable state the phone pushes to the watch. Small, `Codable`,
/// `Sendable`. Carries only what the watch renders — no tokens, no server
/// URL, no note/tag free-text (PHI-adjacent).
public struct WatchSnapshot: Codable, Sendable, Equatable {
    /// A single actionable / recently-acted dose in today's universe. The
    /// `id` is the derived-intake id the phone's `MedicationsStore`
    /// understands (a real server intake id OR a `synth:`-prefixed
    /// placeholder) — the watch echoes it back verbatim in the action so
    /// the phone routes through `markIntakeQuick` (the WriteOutcome quick-mark
    /// path with the `min(scheduledAt, now)` clamp).
    public struct Dose: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let medicationName: String
        /// Free dose text, e.g. "1000 IE". Empty when the med has none.
        public let doseText: String
        public let scheduledAt: Date
        /// `true` once taken today (row shows a check + dims).
        public let isTaken: Bool
        /// `true` for a dose still awaiting action (pending / overdue, not
        /// yet taken or skipped) — these are the rows the watch lets the
        /// user act on.
        public let isActionable: Bool
        /// `true` for injection meds (syringe glyph; the site itself is set
        /// on the phone, not the watch).
        public let isInjection: Bool

        public init(
            id: String,
            medicationName: String,
            doseText: String,
            scheduledAt: Date,
            isTaken: Bool,
            isActionable: Bool,
            isInjection: Bool
        ) {
            self.id = id
            self.medicationName = medicationName
            self.doseText = doseText
            self.scheduledAt = scheduledAt
            self.isTaken = isTaken
            self.isActionable = isActionable
            self.isInjection = isInjection
        }
    }

    /// **v0.15.2 W-WATCH-COMPLICATIONS** — the latest Personal Health Score,
    /// for the watch-face score-ring complication. Mirrors the server value +
    /// band token verbatim (never recomputed). The complication paints the ring
    /// fraction from `score / 100` and maps the band to the signal colour,
    /// matching the in-app `HLScoreRing` / phone score widget.
    public struct HealthScoreGlance: Codable, Sendable, Equatable {
        /// Composite Personal Health Score, clamped 0…100 on construction.
        public let score: Int
        /// Server band token (`"green"` / `"yellow"` / `"red"`), or `nil` when
        /// the server emitted no band — the complication then derives the signal
        /// from the numeric thresholds (≥ 70 ok / ≥ 40 warn / else bad).
        public let band: String?

        public init(score: Int, band: String?) {
            self.score = max(0, min(100, score))
            self.band = band
        }

        /// Ring fill fraction, `score / 100`, clamped `0…1`.
        public var fraction: Double {
            max(0, min(1, Double(score) / 100))
        }

        /// Resolved band token (`"green"` / `"yellow"` / `"red"`) the
        /// complication colours its signal by: prefer the server band, else
        /// derive from the numeric thresholds (≥ 70 green / ≥ 40 yellow / else
        /// red) — the SAME banding as the in-app `HLScoreRing` / phone widget.
        /// Pulled into the shared contract so it's unit-testable without a
        /// WidgetKit host (the complication itself isn't reachable from tests).
        public var signalBand: String {
            switch band {
            case "green", "yellow", "red": band ?? "red"
            default: score >= 70 ? "green" : (score >= 40 ? "yellow" : "red")
            }
        }
    }

    /// **v0.15.2 W-WATCH-COMPLICATIONS** — the most-recent measurement reading,
    /// for the watch-face latest-measurement complication. The phone pre-formats
    /// `formattedValue` through the canonical descriptor formatter (so the
    /// complication shows the SAME string the dashboard tile does) and carries
    /// the unit + SF Symbol + timestamp. No note, no source — value-free beyond
    /// the reading itself.
    public struct LatestMeasurement: Codable, Sendable, Equatable {
        /// `MetricKind` raw value (e.g. `"weight"`, `"bloodPressure"`).
        public let kindRaw: String
        /// Localized metric title, e.g. "Blood pressure".
        public let title: String
        /// Pre-formatted primary value, e.g. "72.4" / "128/82" — exactly the
        /// string the in-app tile renders (em-dash for a non-finite reading).
        public let formattedValue: String
        /// Unit suffix, e.g. "kg" / "mmHg" / "" (cumulative kinds carry none).
        public let unit: String
        /// SF Symbol identifier for the kind.
        public let symbol: String
        /// When the reading was recorded — drives the relative-time sub-line.
        public let recordedAt: Date

        public init(
            kindRaw: String,
            title: String,
            formattedValue: String,
            unit: String,
            symbol: String,
            recordedAt: Date
        ) {
            self.kindRaw = kindRaw
            self.title = title
            self.formattedValue = formattedValue
            self.unit = unit
            self.symbol = symbol
            self.recordedAt = recordedAt
        }
    }

    /// Today's actionable + recently-acted doses, soonest-first.
    public let doses: [Dose]
    /// Today's total scheduled count (for the "x/y" compliance line).
    public let scheduledCount: Int
    /// Doses already taken today.
    public let takenCount: Int
    /// Most-recent mood score 1…5 logged *today*, or `nil` if none today.
    /// Kept as a quiet "last logged" hint — NOT a day-level lock; the watch
    /// allows unlimited mood check-ins/day.
    public let recentMoodScore: Int?
    /// How many mood entries were logged *today* (caller-locale day). Drives
    /// the wrist's quiet "N today" subhead. Tolerant-decodes to 0 for an
    /// older/partial blob.
    public let moodCountToday: Int
    /// `false` when the phone can't accept writes (no auth token AND not
    /// standalone) — the watch shows a calm "sign in on iPhone" state.
    /// `true` when the phone is signed-in **or** running standalone (a
    /// no-server user has a working LOCAL write path), so the watch lets the
    /// user log mood / mark intakes. F4: decouples watch usability from a
    /// token-only check.
    public let signedIn: Bool
    /// **v0.15.2 W-WATCH-COMPLICATIONS** — the latest server-resolved Personal
    /// Health Score, for the watch-face health-score-ring complication. `nil`
    /// until the dashboard score has loaded (or on logout). Mirrored verbatim
    /// from the server — the watch never recomputes it (server-first).
    public let healthScore: HealthScoreGlance?
    /// **v0.15.2 W-WATCH-COMPLICATIONS** — the most-recent measurement reading,
    /// for the watch-face latest-measurement complication. Carries a single
    /// pre-formatted value (formatted phone-side through the canonical
    /// `MetricKindDescriptor` formatter so it matches the dashboard tile) plus
    /// its unit + symbol + timestamp. `nil` until a measurement has loaded.
    public let latestMeasurement: LatestMeasurement?
    /// When the snapshot was generated (staleness / debugging).
    public let generatedAt: Date

    public init(
        doses: [Dose],
        scheduledCount: Int,
        takenCount: Int,
        recentMoodScore: Int?,
        moodCountToday: Int = 0,
        signedIn: Bool,
        healthScore: HealthScoreGlance? = nil,
        latestMeasurement: LatestMeasurement? = nil,
        generatedAt: Date
    ) {
        self.doses = doses
        self.scheduledCount = scheduledCount
        self.takenCount = takenCount
        self.recentMoodScore = recentMoodScore
        self.moodCountToday = moodCountToday
        self.signedIn = signedIn
        self.healthScore = healthScore
        self.latestMeasurement = latestMeasurement
        self.generatedAt = generatedAt
    }

    /// Decode tolerant of an older/partial blob so a snapshot written by a
    /// future-or-past build still reads (the watch then shows its empty
    /// state rather than failing to update).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        doses = try c.decodeIfPresent([Dose].self, forKey: .doses) ?? []
        scheduledCount = try c.decodeIfPresent(Int.self, forKey: .scheduledCount) ?? 0
        takenCount = try c.decodeIfPresent(Int.self, forKey: .takenCount) ?? 0
        recentMoodScore = try c.decodeIfPresent(Int.self, forKey: .recentMoodScore)
        moodCountToday = try c.decodeIfPresent(Int.self, forKey: .moodCountToday) ?? 0
        // Back/forward compat: prefer the new `canLog`, fall back to the
        // historical `signedIn` key so a blob from either build still reads.
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .canLog)
            ?? c.decodeIfPresent(Bool.self, forKey: .signedIn)
            ?? false
        healthScore = try c.decodeIfPresent(HealthScoreGlance.self, forKey: .healthScore)
        latestMeasurement = try c.decodeIfPresent(LatestMeasurement.self, forKey: .latestMeasurement)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(doses, forKey: .doses)
        try c.encode(scheduledCount, forKey: .scheduledCount)
        try c.encode(takenCount, forKey: .takenCount)
        try c.encodeIfPresent(recentMoodScore, forKey: .recentMoodScore)
        try c.encode(moodCountToday, forKey: .moodCountToday)
        // Emit BOTH keys so an older watch build (reads `signedIn`) and a
        // newer one (reads `canLog`) both work.
        try c.encode(signedIn, forKey: .signedIn)
        try c.encode(signedIn, forKey: .canLog)
        try c.encodeIfPresent(healthScore, forKey: .healthScore)
        try c.encodeIfPresent(latestMeasurement, forKey: .latestMeasurement)
        try c.encode(generatedAt, forKey: .generatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case doses, scheduledCount, takenCount, recentMoodScore, moodCountToday, signedIn, canLog
        case healthScore, latestMeasurement, generatedAt
    }

    /// Fraction taken, clamped `0...1`. A day with no scheduled doses reads
    /// as complete (1.0) so the watch ring isn't an alarming empty circle.
    public var complianceFraction: Double {
        guard scheduledCount > 0 else { return 1 }
        return max(0, min(1, Double(takenCount) / Double(scheduledCount)))
    }

    /// **Privacy H4 (audit-v0162)** — `true` when this snapshot carries no PHI:
    /// no doses, no schedule/taken counts, no mood, no score, no measurement, and
    /// the write path is closed (`!signedIn`). The phone pushes exactly this
    /// shape (``placeholder``) on logout; the watch treats a cleared snapshot as
    /// "wipe the local `watch-snapshot.json`" so the previous user's data does
    /// not persist at rest on the wrist. `generatedAt` is intentionally ignored
    /// (a cleared snapshot is cleared regardless of when it was minted).
    public var isCleared: Bool {
        doses.isEmpty
            && scheduledCount == 0
            && takenCount == 0
            && recentMoodScore == nil
            && moodCountToday == 0
            && healthScore == nil
            && latestMeasurement == nil
            && !signedIn
    }

    /// Neutral state before the phone has pushed anything (or signed out).
    public static let placeholder = WatchSnapshot(
        doses: [],
        scheduledCount: 0,
        takenCount: 0,
        recentMoodScore: nil,
        signedIn: false,
        generatedAt: .distantPast
    )
}

/// **Pure count-combine math for the wrist's "N today" mood subhead.**
///
/// The watch keeps an optimistic layer ON TOP of the phone's authoritative
/// `WatchSnapshot.moodCountToday`: each wrist tap is recorded as a `pending`
/// timestamp (the moment the user tapped). The displayed count is the
/// snapshot count PLUS the wrist taps the snapshot does not yet reflect — a
/// **delta**, never a `max`. This is pulled out as a free function (in the
/// shared, Foundation-only contract) so both the watch client AND the test
/// target can exercise it; the client itself isn't reachable from
/// `HealthLogTests`.
///
/// Rules:
///   - A pending tap counts iff it happened AFTER the snapshot was generated
///     (`tapTime > snapshot.generatedAt`). A snapshot generated after the tap
///     is assumed to already include it, so the delta drops to 0 (no
///     double-count of an offline burst the phone has since processed).
///   - This makes day-boundary correct for free: at local midnight the phone
///     pushes a fresh snapshot (`moodCountToday == 0`, newer `generatedAt`).
///     Any taps from the previous evening are older than the new snapshot, so
///     they no longer count → the wrist honestly follows the post-midnight 0.
public enum WatchMoodCount {
    /// The pending taps that a given snapshot does NOT yet reflect — those
    /// whose tap time is strictly newer than the snapshot's `generatedAt`.
    /// Used both to render the count and to prune resolved taps when a fresh
    /// snapshot lands (call with the new snapshot, keep the result).
    public static func unreflectedTaps(
        pendingTaps: [Date],
        snapshotGeneratedAt: Date
    ) -> [Date] {
        pendingTaps.filter { $0 > snapshotGeneratedAt }
    }

    /// The number to show in the "N today" subhead: the snapshot's
    /// authoritative count plus the wrist taps it doesn't yet reflect.
    public static func displayedCount(
        snapshotCount: Int,
        pendingTaps: [Date],
        snapshotGeneratedAt: Date
    ) -> Int {
        let delta = unreflectedTaps(pendingTaps: pendingTaps, snapshotGeneratedAt: snapshotGeneratedAt).count
        return max(0, snapshotCount) + delta
    }
}

/// **v0.15.2 W-WATCH-COMPLICATIONS — complication deep-link targets.**
///
/// The watch-face complications carry a `healthlog://…` `widgetURL`; tapping one
/// opens the WATCH app (never the phone) to the matching task. Resolution lives
/// here in the shared, Foundation-only contract so it's unit-testable without a
/// SwiftUI host — the watch app maps the result onto its `TabView` selection.
public enum WatchDeepLinkTarget: String, Sendable, Equatable {
    case medications
    case mood
    case measure

    /// Map a complication deep link's host onto a wrist tab. Accepts the
    /// canonical hosts plus a couple of synonyms; unknown hosts → `nil`.
    public init?(url: URL) {
        switch url.host {
        case "medications", "nextDose", "healthScore": self = .medications
        case "mood": self = .mood
        case "measure", "measurement", "log": self = .measure
        default: return nil
        }
    }
}

/// What the watch asks the phone to do. Raw payload, no identity — the
/// identity (`id`) lives on the wrapping ``WatchAction`` so the phone can echo
/// it back in a ``WatchAck``.
public enum WatchActionKind: Codable, Sendable, Equatable {
    /// Mark a dose taken / skipped / snoozed. `intakeId` is the derived
    /// intake id from the snapshot's `Dose.id`.
    case markIntake(intakeId: String, status: WatchIntakeStatus, at: Date)
    /// Quick-log a mood (1…5). No note / tags from the watch.
    case logMood(score: Int, at: Date)
    /// Quick-capture a manual measurement at the wrist. `value` is the primary
    /// scalar (weight kg, glucose mg/dL, pulse bpm, or BP systolic). `secondary`
    /// carries the BP diastolic and is `nil` for every scalar kind. The phone
    /// bridges `kind` onto `MetricKind` and funnels the value into the SAME
    /// `MeasurementsStore` capture path the app's `MeasureSheet` uses (server
    /// write + Outbox + HK mirror) — no parallel write path.
    case logMeasurement(kind: WatchMeasurementKind, value: Double, secondary: Double?, at: Date)
}

/// An action the watch asks the phone to perform. Encoded into a durable
/// `transferUserInfo` payload; the phone bridges it onto the live stores and
/// echoes a ``WatchAck`` back keyed by `id` so the watch can show honest
/// state (F2). `id` is a stable UUID minted on the watch at tap time.
public struct WatchAction: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: WatchActionKind

    public init(id: String = UUID().uuidString, kind: WatchActionKind) {
        self.id = id
        self.kind = kind
    }

    /// Tolerant decode: an action blob from an OLDER watch build has no `id`
    /// and stores the kind's fields at the top level (it WAS the enum). Detect
    /// that shape and synthesise an id so the phone still processes it (it just
    /// can't ack a build that wouldn't understand the ack anyway).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .id),
           let kind = try c.decodeIfPresent(WatchActionKind.self, forKey: .kind)
        {
            self.id = id
            self.kind = kind
        } else {
            // Legacy flat shape — decode the kind from the same container.
            id = UUID().uuidString
            kind = try WatchActionKind(from: decoder)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind
    }

    /// Convenience: a mark-intake action with a fresh id.
    public static func markIntake(intakeId: String, status: WatchIntakeStatus, at: Date) -> WatchAction {
        WatchAction(kind: .markIntake(intakeId: intakeId, status: status, at: at))
    }

    /// Convenience: a log-mood action with a fresh id.
    public static func logMood(score: Int, at: Date) -> WatchAction {
        WatchAction(kind: .logMood(score: score, at: at))
    }

    /// Convenience: a quick-capture measurement action with a fresh id.
    public static func logMeasurement(
        kind: WatchMeasurementKind, value: Double, secondary: Double? = nil, at: Date
    ) -> WatchAction {
        WatchAction(kind: .logMeasurement(kind: kind, value: value, secondary: secondary, at: at))
    }
}

/// The phone's verdict on a processed ``WatchAction``, sent back to the watch
/// so the wrist shows an HONEST state instead of a blind optimistic check (F2).
public enum WatchAckOutcome: String, Codable, Sendable, Equatable {
    /// The write landed on the server (or local mirror) — fully done.
    case saved
    /// The phone couldn't reach the server but the write is durably queued in
    /// the Outbox and will sync — show "Saved, will sync."
    case queued
    /// The phone couldn't accept the write at all (e.g. not signed in / not
    /// standalone) — show "Couldn't save."
    case failed
}

/// A tiny phone→watch acknowledgement for one action `id`. Durable
/// (`transferUserInfo`) so it survives an unreachable watch.
public struct WatchAck: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let outcome: WatchAckOutcome
    public let at: Date

    public init(id: String, outcome: WatchAckOutcome, at: Date = .now) {
        self.id = id
        self.outcome = outcome
        self.at = at
    }
}

// MARK: - Transport

/// Plist-safe encode/decode for WatchConnectivity dictionaries. WC payloads
/// must be property-list types, so each side wraps a single JSON `Data`
/// blob (which IS plist-safe) under a stable key. Both targets use these
/// helpers so the wire format is one piece of code.
public enum WatchTransport {
    public static let snapshotKey = "hl.snapshot"
    public static let actionKey = "hl.action"
    public static let ackKey = "hl.ack"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns `[String: Data]` (Sendable) rather than `[String: Any]` so the
    /// payload can be captured into a `sendMessage` error handler / `Task`
    /// under Swift 6 strict concurrency. `[String: Data]` converts implicitly
    /// to the `[String: Any]` the WatchConnectivity APIs accept.
    public static func encode(snapshot: WatchSnapshot) -> [String: Data] {
        guard let data = try? encoder.encode(snapshot) else { return [:] }
        return [snapshotKey: data]
    }

    public static func decodeSnapshot(_ dict: [String: Any]) -> WatchSnapshot? {
        guard let data = dict[snapshotKey] as? Data else { return nil }
        return try? decoder.decode(WatchSnapshot.self, from: data)
    }

    public static func encode(action: WatchAction) -> [String: Data] {
        guard let data = try? encoder.encode(action) else { return [:] }
        return [actionKey: data]
    }

    public static func decodeAction(_ dict: [String: Any]) -> WatchAction? {
        guard let data = dict[actionKey] as? Data else { return nil }
        return try? decoder.decode(WatchAction.self, from: data)
    }

    public static func encode(ack: WatchAck) -> [String: Data] {
        guard let data = try? encoder.encode(ack) else { return [:] }
        return [ackKey: data]
    }

    public static func decodeAck(_ dict: [String: Any]) -> WatchAck? {
        guard let data = dict[ackKey] as? Data else { return nil }
        return try? decoder.decode(WatchAck.self, from: data)
    }
}
