import Foundation

/// Wire shape of `GET /api/sleep/rhythm` (parity Build 4 · item 4.7).
///
/// The route is a thin auth + module-gate boundary over the server's
/// `buildSleepRhythm` assembler; it emits THREE peer signals in one read:
///
///   - ``sleepDebt`` — the rolling need-minus-got BALANCE (surplus-credited,
///     floored at zero), with a calm `partial` state under the night floor.
///   - ``chronotype`` — MCTQ MSF / MSFsc band + social jetlag, with a
///     `learning` state until enough alarm-free nights exist.
///   - ``averagePerNight`` — mean asleep minutes over the scorable window.
///
/// **Audit correction (verified against `W/src/app/api/sleep/rhythm/route.ts`
/// + `W/src/lib/insights/derived/sleep-rhythm.ts` at read time).** The audit row
/// `09-…md:135` records the server doc-comment claim that iOS already renders
/// this payload as STALE — correct, there was no iOS caller. The payload shape
/// itself, however, matched the audit's expectation exactly, including the
/// third `averagePerNight` card the audit lists separately at `:134`. No
/// contract drift was found; this file is built against the route as it is.
///
/// **Tolerant decode (the whole point of the explicit `init(from:)` below).**
/// Every one of the three blocks is optional at the DTO level: a server that
/// omits a block, sends `null` for it, or sends a block whose `state` string
/// this build has never seen must degrade to "that card self-suppresses",
/// never to a thrown decode that blanks the whole sleep page. Minute counts
/// decode via `Double` because the server rounds most — but not provably all —
/// of them, and an unrounded `419.5` must not throw.
public struct SleepRhythmDTO: Decodable, Sendable, Equatable {
    /// Rolling sleep-debt balance. `nil` ⇒ absent / null on the wire.
    public let sleepDebt: SleepDebtDTO?
    /// MCTQ chronotype + social jetlag. `nil` ⇒ absent / null on the wire.
    public let chronotype: ChronotypeDTO?
    /// Mean sleep per night over the rhythm window. `nil` ⇒ absent / null.
    public let averagePerNight: AverageSleepDTO?

    /// `true` when the payload carries nothing renderable — the section
    /// suppresses itself rather than showing three empty cards.
    public var isEmpty: Bool {
        sleepDebt == nil && chronotype == nil && averagePerNight == nil
    }

    private enum CodingKeys: String, CodingKey {
        case sleepDebt, chronotype, averagePerNight
    }

    public init(
        sleepDebt: SleepDebtDTO? = nil,
        chronotype: ChronotypeDTO? = nil,
        averagePerNight: AverageSleepDTO? = nil
    ) {
        self.sleepDebt = sleepDebt
        self.chronotype = chronotype
        self.averagePerNight = averagePerNight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each block decodes INDEPENDENTLY and lossily: one malformed block
        // must not take the other two down with it.
        sleepDebt = try? c.decodeIfPresent(SleepDebtDTO.self, forKey: .sleepDebt)
        chronotype = try? c.decodeIfPresent(ChronotypeDTO.self, forKey: .chronotype)
        averagePerNight = try? c.decodeIfPresent(AverageSleepDTO.self, forKey: .averagePerNight)
    }
}

// MARK: - Sleep debt

/// Rolling sleep-debt balance — `SleepDebtDto` on the wire.
///
/// `debtMinutes` is the balance the user still OWES right now, not a sum of
/// every historic deficit: a short night adds its shortfall, a long night pays
/// the balance down at a partial recovery rate, and the balance floors at 0.
/// iOS **renders** this figure; it never recomputes it (the server owns the
/// need table and the recovery curve).
public struct SleepDebtDTO: Decodable, Sendable, Equatable {
    /// `partial` until the window holds enough tracked nights — the card then
    /// shows the calm "still learning" copy and asserts no balance.
    public enum State: String, Decodable, Sendable {
        case partial, ready
    }

    public let state: State
    /// Minutes still owed. `0` with `state == .ready` reads "all caught up".
    public let debtMinutes: Int
    /// The age-resolved nightly sleep need the balance is measured against.
    public let needMinutes: Int
    public let nightsCounted: Int
    public let windowNights: Int
    public let nightsUntilReady: Int
    /// The `MeasurementSource` the figure resolves FROM. `"COMPUTED"` means
    /// HealthLog's own rolling-balance estimate (the only producer today) —
    /// the card discloses that so the number is never mistaken for a
    /// wearable's native debt, which uses a different need model.
    public let source: String?

    /// `true` when the balance is asserted AND settled at zero.
    public var isCaughtUp: Bool {
        state == .ready && debtMinutes <= 0
    }

    private enum CodingKeys: String, CodingKey {
        case state, debtMinutes, needMinutes
        case nightsCounted, windowNights, nightsUntilReady, source
    }

    public init(
        state: State,
        debtMinutes: Int,
        needMinutes: Int,
        nightsCounted: Int,
        windowNights: Int,
        nightsUntilReady: Int,
        source: String? = nil
    ) {
        self.state = state
        self.debtMinutes = debtMinutes
        self.needMinutes = needMinutes
        self.nightsCounted = nightsCounted
        self.windowNights = windowNights
        self.nightsUntilReady = nightsUntilReady
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown / absent state → `partial`, the state that asserts nothing.
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .partial
        debtMinutes = try SleepRhythmDecoding.minutes(c, .debtMinutes) ?? 0
        needMinutes = try SleepRhythmDecoding.minutes(c, .needMinutes) ?? 0
        nightsCounted = try SleepRhythmDecoding.minutes(c, .nightsCounted) ?? 0
        windowNights = try SleepRhythmDecoding.minutes(c, .windowNights) ?? 0
        nightsUntilReady = try SleepRhythmDecoding.minutes(c, .nightsUntilReady) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

// MARK: - Average sleep per night

/// Mean asleep minutes per scorable night — `AverageSleepDto` on the wire.
///
/// Reads its OWN sub-window (every scorable night, up to the assembler's
/// 42-day read), which is deliberately WIDER than the debt card's 5-night
/// balance window. The caption discloses `nightsCounted` so the two figures
/// read as two honest spans rather than one that contradicts the other.
public struct AverageSleepDTO: Decodable, Sendable, Equatable {
    public enum State: String, Decodable, Sendable {
        case partial, ready
    }

    public let state: State
    /// Mean asleep minutes per night. `0` while `partial`.
    public let averageMinutes: Int
    public let nightsCounted: Int
    public let nightsUntilReady: Int

    private enum CodingKeys: String, CodingKey {
        case state, averageMinutes, nightsCounted, nightsUntilReady
    }

    public init(
        state: State,
        averageMinutes: Int,
        nightsCounted: Int,
        nightsUntilReady: Int
    ) {
        self.state = state
        self.averageMinutes = averageMinutes
        self.nightsCounted = nightsCounted
        self.nightsUntilReady = nightsUntilReady
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .partial
        averageMinutes = try SleepRhythmDecoding.minutes(c, .averageMinutes) ?? 0
        nightsCounted = try SleepRhythmDecoding.minutes(c, .nightsCounted) ?? 0
        nightsUntilReady = try SleepRhythmDecoding.minutes(c, .nightsUntilReady) ?? 0
    }
}

// MARK: - Chronotype

/// MCTQ chronotype band, derived server-side from observed free-day sleep
/// midpoints (Roenneberg 2003/2007) — never from a questionnaire.
public enum ChronotypeBand: String, Decodable, Sendable, CaseIterable {
    case extremeEarly = "extreme_early"
    case early
    case intermediate
    case late
    case extremeLate = "extreme_late"

    /// Localized band label — mirrors the web `insights.sleep.chronotype.band.*`
    /// vocabulary word for word.
    public var displayKey: LocalizedStringResource {
        switch self {
        case .extremeEarly: "sleep.chronotype.band.extremeEarly"
        case .early: "sleep.chronotype.band.early"
        case .intermediate: "sleep.chronotype.band.intermediate"
        case .late: "sleep.chronotype.band.late"
        case .extremeLate: "sleep.chronotype.band.extremeLate"
        }
    }
}

/// MCTQ chronotype + social jetlag — `ChronotypeDto` on the wire.
///
/// All four measures are minutes-of-day / minute spans in the user's WALL
/// clock, computed server-side off the same canonical midpoint the Sleep
/// Score's timing sub-score reads. `nil` on any of them means "not asserted",
/// which the card renders as an omitted row — never as `0`.
public struct ChronotypeDTO: Decodable, Sendable, Equatable {
    /// `learning` until enough free-day nights exist; no band is asserted then.
    public enum State: String, Decodable, Sendable {
        case learning, ready
    }

    public let state: State
    /// Mid-sleep on free days, minutes-of-day (0…1439). `nil` while learning.
    public let msfMinutes: Int?
    /// Sleep-debt-corrected mid-sleep on free days (MSFsc). `nil` while learning.
    public let msfScMinutes: Int?
    /// Band off MSFsc. `nil` while learning, or when the server sent a band
    /// string this build does not know (forward-compatible degrade).
    public let band: ChronotypeBand?
    /// Circular |MSF_work − MSF_free| in minutes. `nil` when one side of the
    /// comparison has no midpoint at all.
    public let socialJetlagMinutes: Int?
    public let freeNightsCounted: Int
    public let workNightsCounted: Int
    public let freeNightsUntilReady: Int

    private enum CodingKeys: String, CodingKey {
        case state, msfMinutes, msfScMinutes, band, socialJetlagMinutes
        case freeNightsCounted, workNightsCounted, freeNightsUntilReady
    }

    public init(
        state: State,
        msfMinutes: Int? = nil,
        msfScMinutes: Int? = nil,
        band: ChronotypeBand? = nil,
        socialJetlagMinutes: Int? = nil,
        freeNightsCounted: Int = 0,
        workNightsCounted: Int = 0,
        freeNightsUntilReady: Int = 0
    ) {
        self.state = state
        self.msfMinutes = msfMinutes
        self.msfScMinutes = msfScMinutes
        self.band = band
        self.socialJetlagMinutes = socialJetlagMinutes
        self.freeNightsCounted = freeNightsCounted
        self.workNightsCounted = workNightsCounted
        self.freeNightsUntilReady = freeNightsUntilReady
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? .learning
        msfMinutes = try SleepRhythmDecoding.minutes(c, .msfMinutes)
        msfScMinutes = try SleepRhythmDecoding.minutes(c, .msfScMinutes)
        // A future server band string degrades to `nil` (no band shown) rather
        // than throwing the whole chronotype block away.
        band = try? c.decodeIfPresent(ChronotypeBand.self, forKey: .band)
        socialJetlagMinutes = try SleepRhythmDecoding.minutes(c, .socialJetlagMinutes)
        freeNightsCounted = try SleepRhythmDecoding.minutes(c, .freeNightsCounted) ?? 0
        workNightsCounted = try SleepRhythmDecoding.minutes(c, .workNightsCounted) ?? 0
        freeNightsUntilReady = try SleepRhythmDecoding.minutes(c, .freeNightsUntilReady) ?? 0
    }
}

// MARK: - Shared tolerant minute decoding

/// Shared minute/count decoding for the rhythm DTOs.
///
/// Every numeric on this wire is conceptually a whole minute or a whole night,
/// but the server derives several of them from float sums. Decoding through
/// `Double` and rounding at the edge means a `419.5` never throws, and
/// `Int(safeServer:)` (W-CRASHGUARD) turns a non-finite / out-of-range value
/// into an ABSENT number instead of trapping.
enum SleepRhythmDecoding {
    static func minutes<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> Int? {
        try c.decodeIfPresent(Double.self, forKey: key).flatMap { Int(safeServer: $0) }
    }
}
