import Foundation

/// **The tiny medication summary the Home / Lock-Screen
/// widgets paint from.**
///
/// The app writes this into the shared App Group container whenever the
/// medication schedule / today's intakes change (see
/// `WidgetSnapshotWriter`); the widget `TimelineProvider`s read it (fast,
/// offline-safe) and never touch the network. Kept deliberately small,
/// `Codable` + `Sendable`, carrying only what the two widgets render:
///
/// - `nextDose` — the soonest due (or currently-overdue) dose, if any.
/// - `compliance` — today's taken / scheduled counts for the ring.
///
/// **No PII beyond the medication name** (which is already on the Lock
/// Screen via the Live Activity) — no tokens, no server URL, no identifiers
/// the widget doesn't need to render.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// The soonest dose the user still needs to act on. `nil` when nothing
    /// is due in-window (the widget then shows an "all done" / empty state).
    public let nextDose: NextDose?

    /// Today's adherence summary for the compliance ring.
    public let compliance: ComplianceSummary

    /// The most-recent mood entry, for the interactive
    /// mood widget's glance. `nil` when the user has never logged a mood (or
    /// signed out). Optional on decode so an older snapshot (pre-mood-field)
    /// still reads.
    public let recentMood: RecentMood?

    /// **v0.15 companion-#3** — the latest server-resolved Personal Health
    /// Score, for the health-score-ring Home / Lock-Screen widget. `nil` until
    /// the dashboard score has loaded (or on logout). Optional on decode so an
    /// older snapshot (pre-score-field) still reads. The value is mirrored
    /// verbatim from the server (`/api/dashboard/snapshot` `healthScore`) — the widget
    /// never recomputes it (server-first).
    public let healthScore: HealthScoreGlance?

    /// **v0.15 companion-#3** — the most-recent measurement reading the
    /// latest-measurement widget glances. Carries a single pre-formatted value
    /// (the app formats it through the canonical `MetricKindDescriptor`
    /// formatter so the widget shows the SAME string the dashboard tile does)
    /// plus its unit + kind id + timestamp. `nil` until a measurement has
    /// loaded (or on logout). Optional on decode so an older snapshot reads.
    public let latestMeasurement: LatestMeasurement?

    /// The choosable readings of the configurable measurement widget: one glance
    /// per named, non-cumulative kind the app holds, newest first, each with a
    /// short trend. Empty on a snapshot written before the widget became
    /// configurable, which is what keeps a placed widget on its old reading.
    public let metricGlances: [MetricGlance]

    /// When the snapshot was written. Lets a widget show staleness if the
    /// app hasn't refreshed it in a long time (and aids debugging).
    public let generatedAt: Date

    /// **W-B183 coherence — the app's resolved `HLTimeFormat` raw value**
    /// (`AUTO` / `H12` / `H24`) captured at snapshot-write time. The widget
    /// renders every dose time through `HLTimeFormat(rawValue:)` so it shows
    /// the SAME clock string the app does (12h vs 24h vs locale-auto).
    ///
    /// **Why carry it instead of reading UserDefaults in the widget:** the
    /// preference mirror (`HLTimeFormat.defaultsKey`) lives in the app's
    /// `UserDefaults.standard`, which is NOT shared with the widget process —
    /// the extension would always read `.auto`. Carrying the resolved value in
    /// the App-Group snapshot is the only way the widget honours the server's
    /// `User.timeFormat` pick without a second (broken) cross-process read.
    /// Defaults to `HLTimeFormat.auto.rawValue` ("AUTO") on a legacy snapshot
    /// (pre-W-B183 key absent) so the device locale governs until the next
    /// write.
    public let timeFormatRaw: String

    public init(
        nextDose: NextDose?,
        compliance: ComplianceSummary,
        recentMood: RecentMood? = nil,
        healthScore: HealthScoreGlance? = nil,
        latestMeasurement: LatestMeasurement? = nil,
        metricGlances: [MetricGlance] = [],
        timeFormatRaw: String = "AUTO",
        generatedAt: Date
    ) {
        self.nextDose = nextDose
        self.compliance = compliance
        self.recentMood = recentMood
        self.healthScore = healthScore
        self.latestMeasurement = latestMeasurement
        self.metricGlances = metricGlances
        self.timeFormatRaw = timeFormatRaw
        self.generatedAt = generatedAt
    }

    /// Decode with a `nil` mood fallback so a snapshot written by a pre-mood
    /// build (no `recentMood` key) still reads — the widget then shows its
    /// empty/prompt state. `timeFormatRaw` falls back to "AUTO" on a pre-W-B183
    /// snapshot (key absent) so the device locale governs the clock.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextDose = try c.decodeIfPresent(NextDose.self, forKey: .nextDose)
        compliance = try c.decode(ComplianceSummary.self, forKey: .compliance)
        recentMood = try c.decodeIfPresent(RecentMood.self, forKey: .recentMood)
        healthScore = try c.decodeIfPresent(HealthScoreGlance.self, forKey: .healthScore)
        latestMeasurement = try c.decodeIfPresent(LatestMeasurement.self, forKey: .latestMeasurement)
        metricGlances = (try? c.decodeIfPresent([MetricGlance].self, forKey: .metricGlances)) ?? []
        timeFormatRaw = try c.decodeIfPresent(String.self, forKey: .timeFormatRaw) ?? "AUTO"
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case nextDose
        case compliance
        case recentMood
        case healthScore
        case latestMeasurement
        case metricGlances
        case timeFormatRaw
        case generatedAt
    }

    /// A single upcoming / overdue dose surfaced by the next-dose widget.
    public struct NextDose: Codable, Sendable, Equatable {
        /// Server medication id — the stable key the interactive
        /// "Genommen" button records the intake against.
        public let medicationId: String

        /// Display name, e.g. "Vitamin D". Server-supplied content.
        public let medicationName: String

        /// Dose text, e.g. "1000 IE". Server-supplied free text. Empty
        /// string when the medication has no dose text.
        public let doseText: String

        /// The scheduled fire instant this dose is due at. Drives the
        /// "fällig um HH:mm" sub-line + the timeline refresh anchor.
        public let scheduledAt: Date

        public init(
            medicationId: String,
            medicationName: String,
            doseText: String,
            scheduledAt: Date
        ) {
            self.medicationId = medicationId
            self.medicationName = medicationName
            self.doseText = doseText
            self.scheduledAt = scheduledAt
        }
    }

    /// Today's adherence: how many of today's scheduled doses are taken.
    public struct ComplianceSummary: Codable, Sendable, Equatable {
        /// Total doses scheduled for today (server-emitted + synthesised
        /// placeholders — the same `derivedTodayIntakes` universe the app
        /// renders). Drives the literal "x/y doses" centre count, which still
        /// reflects TODAY's schedule (honest to the in-app today rows).
        public let scheduled: Int

        /// Doses already marked taken today.
        public let taken: Int

        /// **W-B183 coherence — the SERVER dose-history ledger's adherence
        /// percentage (0…100), or `nil` when the server value hasn't loaded.**
        ///
        /// This is the SAME number the in-app medication card + `LedgerHistory
        /// Section` paint (server `GET /api/medications/{id}/compliance` →
        /// `complianceCardSnapshots`, the short-window rate the card shows),
        /// aggregated across the user's active medications. The ring ARC tracks
        /// this server value when present so the widget can never paint a
        /// second, client-recomputed adherence number that disagrees with the
        /// app. We NEVER dedup or recompute compliance client-side (double-dose
        /// hazard — that is the server's upsert-on-(med,scheduledFor) job).
        ///
        /// `nil` ⇒ the server ledger value is genuinely unavailable at write
        /// time (cold cache / offline / no active scheduled med). The ring then
        /// falls back to the today-count `fraction` below — clearly the
        /// fallback, not a parallel compute path.
        public let serverCompliancePercent: Int?

        public init(scheduled: Int, taken: Int, serverCompliancePercent: Int? = nil) {
            self.scheduled = scheduled
            self.taken = taken
            self.serverCompliancePercent = serverCompliancePercent
        }

        /// Decode `serverCompliancePercent` tolerantly so a pre-W-B183 snapshot
        /// (key absent) decodes with a `nil` server value and the ring falls
        /// back to the today-count fraction.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scheduled = try c.decode(Int.self, forKey: .scheduled)
            taken = try c.decode(Int.self, forKey: .taken)
            serverCompliancePercent = try c.decodeIfPresent(Int.self, forKey: .serverCompliancePercent)
        }

        private enum CodingKeys: String, CodingKey {
            case scheduled
            case taken
            case serverCompliancePercent
        }

        /// Fraction taken TODAY, clamped to `0...1`. A day with no scheduled
        /// doses reads as fully complete (1.0) so the ring isn't an
        /// alarming empty circle on a rest day. This is the FALLBACK the ring
        /// uses only when ``serverCompliancePercent`` is `nil`.
        public var fraction: Double {
            guard scheduled > 0 else { return 1 }
            return max(0, min(1, Double(taken) / Double(scheduled)))
        }

        /// The fraction the ring ARC should fill, `0...1`. Prefers the SERVER
        /// ledger percentage (÷100, clamped) so the widget mirrors the in-app
        /// compliance number; falls back to today's count ``fraction`` when the
        /// server value is unavailable. The single source the widget paints.
        public var ringFraction: Double {
            guard let percent = serverCompliancePercent else { return fraction }
            return max(0, min(1, Double(percent) / 100))
        }
    }

    /// The user's most-recent mood entry, for the
    /// mood widget glance. Carries only the 1…5 score + the timestamp — no
    /// note, no tags (those are PHI-adjacent free text and the widget never
    /// renders them).
    public struct RecentMood: Codable, Sendable, Equatable {
        /// HealthLog mood score, 1 (lousy) … 5 (great).
        public let score: Int

        /// When the entry was recorded — drives the "Logged HH:mm" sub-line.
        public let loggedAt: Date

        public init(score: Int, loggedAt: Date) {
            self.score = max(1, min(5, score))
            self.loggedAt = loggedAt
        }

        /// `true` when this entry was logged on the same local day as `now` —
        /// the widget shows "logged today" vs. its quick-log prompt.
        public func isToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
            calendar.isDate(loggedAt, inSameDayAs: now)
        }
    }

    /// **v0.15 companion-#3** — the latest Personal Health Score, for the
    /// score-ring widget. Carries the 0…100 composite + the server band token
    /// (green / yellow / red) only — value-free beyond the score itself (no
    /// per-pillar breakdown, no Rest-Mode note). The widget paints the ring
    /// fraction from `score / 100` and maps the band to the single signal dot,
    /// mirroring the in-app `HLScoreRing` look.
    public struct HealthScoreGlance: Codable, Sendable, Equatable {
        /// Composite Personal Health Score, clamped 0…100.
        public let score: Int

        /// Server band token (`"green"` / `"yellow"` / `"red"`) the in-app
        /// surfaces colour the score by, or `nil` when the server emitted no
        /// band (older server) — the widget then derives the signal from the
        /// numeric thresholds (≥ 67 ok / ≥ 34 warn / else bad).
        public let band: String?

        /// When the score was resolved — drives the "as of HH:mm" staleness
        /// sub-line on the rectangular accessory.
        public let resolvedAt: Date

        /// **v1.35.0** — the server-resolved "this composition was
        /// chosen" flag, mirrored verbatim. The widget shows the number with
        /// nothing beside it to qualify it, so it has to be able to say where
        /// the number's make-up came from. Never derived here — a widget that
        /// guessed at provenance would be inventing it.
        ///
        /// Defaults to `false` and decodes tolerantly, so a snapshot written by
        /// an older build reads as "we were not told", which is what it is.
        public let configured: Bool

        public init(score: Int, band: String?, resolvedAt: Date, configured: Bool = false) {
            self.score = max(0, min(100, score))
            self.band = band
            self.resolvedAt = resolvedAt
            self.configured = configured
        }

        /// Same score, band, and provenance. `resolvedAt` is stamped on every
        /// load, so a plain `==` never matches and every load cost a reload.
        public func hasSameContent(as other: Self) -> Bool {
            score == other.score && band == other.band && configured == other.configured
        }

        private enum CodingKeys: String, CodingKey {
            case score, band, resolvedAt, configured
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            score = try max(0, min(100, c.decode(Int.self, forKey: .score)))
            band = try c.decodeIfPresent(String.self, forKey: .band)
            resolvedAt = try c.decode(Date.self, forKey: .resolvedAt)
            configured = (try? c.decodeIfPresent(Bool.self, forKey: .configured)) ?? false
        }

        /// Ring fill fraction, `score / 100`, clamped 0…1.
        public var fraction: Double {
            max(0, min(1, Double(score) / 100))
        }
    }

    /// **v0.15 companion-#3** — the most-recent measurement, for the
    /// latest-measurement widget. The app pre-formats `value` through the
    /// canonical `MetricKindDescriptor` formatter (so the widget shows the SAME
    /// string the dashboard tile does) and carries the unit + kind id +
    /// timestamp. No note, no source — value-free beyond the reading itself.
    public struct LatestMeasurement: Codable, Sendable, Equatable {
        /// `MetricKind` raw value (e.g. `"weight"`, `"bloodPressure"`) — lets
        /// the widget resolve the SF Symbol + localized title for the kind.
        public let kindRaw: String

        /// Localized metric title, e.g. "Blood pressure" — resolved app-side
        /// through the descriptor so the widget process needn't carry the
        /// descriptor catalog.
        public let title: String

        /// Pre-formatted primary value, e.g. "72.4" / "128/82" — exactly the
        /// string the in-app tile renders for this reading.
        public let formattedValue: String

        /// Unit suffix, e.g. "kg" / "mmHg" / "" (cumulative kinds carry none).
        public let unit: String

        /// SF Symbol identifier for the kind (mirrors the descriptor's symbol).
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

        /// POLISH-B B2 (MATRIX M6) — the moment the relative line names. A
        /// measurement cannot lie in the future; a stamp after `now` (a clock
        /// skew between devices, a time zone mix-up at the source) reads as
        /// now instead of "in 4 hours".
        public func shownDate(now: Date) -> Date {
            min(recordedAt, now)
        }
    }

    /// One choosable reading of the measurement widget: the latest value of a
    /// kind, formatted by the app like the dashboard tile, plus a short trend of
    /// one point per day. Carries nothing but the reading.
    public struct MetricGlance: Codable, Sendable, Equatable, Identifiable {
        /// One day of the trend. The value is the day's last reading in the
        /// kind's primary scale (systolic for blood pressure); only the shape
        /// of the line is drawn from it, never a number.
        public struct TrendPoint: Codable, Sendable, Equatable {
            public let date: Date
            public let value: Double

            public init(date: Date, value: Double) {
                self.date = date
                self.value = value
            }
        }

        public let kindRaw: String
        public let title: String
        public let symbol: String
        public let formattedValue: String
        public let unit: String
        public let recordedAt: Date
        /// Oldest first. Fewer than two points draws no line.
        public let trend: [TrendPoint]

        public var id: String {
            kindRaw
        }

        public init(
            kindRaw: String,
            title: String,
            symbol: String,
            formattedValue: String,
            unit: String,
            recordedAt: Date,
            trend: [TrendPoint]
        ) {
            self.kindRaw = kindRaw
            self.title = title
            self.symbol = symbol
            self.formattedValue = formattedValue
            self.unit = unit
            self.recordedAt = recordedAt
            self.trend = trend
        }

        /// The same reading in the shape the single-reading widget paints.
        public var latest: LatestMeasurement {
            LatestMeasurement(
                kindRaw: kindRaw,
                title: title,
                formattedValue: formattedValue,
                unit: unit,
                symbol: symbol,
                recordedAt: recordedAt
            )
        }
    }

    /// The neutral snapshot shown before the app has written anything (or
    /// when signed out): no due dose, an empty-but-complete ring, no mood,
    /// no score, no measurement.
    public static let placeholder = WidgetSnapshot(
        nextDose: nil,
        compliance: ComplianceSummary(scheduled: 0, taken: 0),
        recentMood: nil,
        healthScore: nil,
        latestMeasurement: nil,
        timeFormatRaw: "AUTO",
        generatedAt: .distantPast
    )
}

/// **Atomic read / write of the widget snapshot in the
/// shared App Group container.**
///
/// Shared by the app (writer) and the extension (reader) via source
/// membership so the encode / decode contract is one piece of code. JSON
/// with ISO-8601 dates so a hand-inspection of the file (debugging) is
/// readable and the format survives across builds.
public struct WidgetSnapshotStore: Sendable {
    private let url: URL?

    /// - Parameter url: override for tests; defaults to the resolved App
    ///   Group container file. `nil` (container unavailable) makes every
    ///   operation a safe no-op / `nil` read.
    public init(url: URL? = WidgetAppGroup.snapshotURL()) {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try? SensitiveDataBackupExclusion.secureCreatedItem(at: url)
        }
        self.url = url
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Persist the snapshot atomically. Throws on encode / write failure
    /// so the caller can decide whether to log + carry on (the app does —
    /// a failed widget write must never break a medication mark).
    public func write(_ snapshot: WidgetSnapshot) throws {
        guard let url else { return }
        let data = try Self.makeEncoder().encode(snapshot)
        // v0.12 W1 (security finding W1-2) — the snapshot carries health data
        // (med names + next-dose time + today's mood) in the shared App Group
        // container. Pin an explicit protection class instead of relying on the
        // container default. `.completeFileProtectionUntilFirstUserAuthentication`
        // (NOT `.completeFileProtection`): the widget extension must be able to
        // read the snapshot to build its timeline after the first unlock even
        // while the device is subsequently locked — full protection would make
        // the file unreadable post-lock and the widget would fall back to the
        // placeholder. This still encrypts the bytes at rest before first unlock.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try SensitiveDataBackupExclusion.secureCreatedItem(at: url)
    }

    /// Read the last-written snapshot, or `nil` when none exists yet / the
    /// container is unavailable / the file is corrupt. Never throws — a
    /// widget read should degrade to the placeholder, not crash the
    /// timeline build.
    public func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
