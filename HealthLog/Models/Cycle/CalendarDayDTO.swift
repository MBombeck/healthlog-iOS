import Foundation

// MARK: - CalendarDayDTO

/// One day of `GET /api/cycle/calendar` `data.days` (server
/// `src/lib/cycle/engine-adapter.ts` `buildCalendar`). Moved out of
/// `CycleDTO.swift` under the file-length discipline.
public struct CalendarDayDTO: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String {
        date
    }

    public let date: String
    /// Raw phase string — see ``phaseValue``.
    public let phase: String?
    public let isPredictedPeriod: Bool
    public let isFertileWindow: Bool
    public let isPredictedOvulation: Bool
    public let isPeriodLogged: Bool
    /// Whether a logged cycle opens on this day (server field since v1.37.1).
    /// Defaults `false`; lets a refetch show a start the server folded in or
    /// gave back.
    public let isCycleStart: Bool
    /// v1.39 (#115 1.6) — the 1-based day of the logged cycle THIS date belongs
    /// to, resolved per date by the server. `nil` before the first logged start,
    /// after today, once an open cycle has run past the point where the verdict
    /// stops counting — and from a server older than v1.39, which does not send
    /// it. Never computed on the device.
    public let cycleDay: Int?
    /// v1.39 (#115 1.6) — whether a one-tap period end on this date lands inside
    /// the first days of a logged cycle. `nil` from a server older than v1.39.
    public let periodEndable: Bool?
    public let flow: String?
    public let hasSymptoms: Bool
    public let confidence: Double
    public let basalBodyTempC: Double?
    /// v1.16.15 — the day's BBT reading was excluded from the temperature
    /// evaluation (disturbed). Defaults `false`.
    public let temperatureExcluded: Bool
    public let ovulationTest: String?
    public let cervicalMucus: String?
    /// v1.16.15 — cervix secondary-symptom observations (manual-only).
    public let cervixPosition: String?
    public let cervixFirmness: String?
    public let cervixOpening: String?
    /// v1.39.1 (#1032) — the rest of the day log, carried on the calendar read
    /// so the grid can show that something was logged. Each defaults to "not
    /// logged" when absent (a server older than v1.39.1) or malformed.
    /// Spotting or bleeding outside the period.
    public let intermenstrualBleeding: Bool
    /// Intercourse logged on this day (resolved server-side, envelope included).
    public let sexualActivity: Bool
    public let pregnancyTest: String?
    public let progesteroneTest: String?
    public let contraceptive: String?
    /// Whether the day carries a note. The note text is only on the day-log read.
    public let hasNote: Bool

    public var phaseValue: CyclePhaseValue? {
        phase.flatMap(CyclePhaseValue.init)
    }

    /// Typed flow accessor — the calendar day's logged flow. Drives the CU-25
    /// (#72) flow-without-period reconciliation check, which needs to know
    /// whether the PRECEDING day already carried bleeding.
    public var flowLevel: CycleFlowLevel? {
        flow.flatMap(CycleFlowLevel.init)
    }

    public var cervixPositionValue: CycleCervixPosition? {
        cervixPosition.flatMap(CycleCervixPosition.init)
    }

    public var cervixFirmnessValue: CycleCervixFirmness? {
        cervixFirmness.flatMap(CycleCervixFirmness.init)
    }

    public var cervixOpeningValue: CycleCervixOpening? {
        cervixOpening.flatMap(CycleCervixOpening.init)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        isPredictedPeriod = try c.decodeIfPresent(Bool.self, forKey: .isPredictedPeriod) ?? false
        isFertileWindow = try c.decodeIfPresent(Bool.self, forKey: .isFertileWindow) ?? false
        isPredictedOvulation = try c.decodeIfPresent(Bool.self, forKey: .isPredictedOvulation) ?? false
        isPeriodLogged = try c.decodeIfPresent(Bool.self, forKey: .isPeriodLogged) ?? false
        isCycleStart = (try? c.decodeIfPresent(Bool.self, forKey: .isCycleStart)) ?? false
        // Tolerant: a malformed value reads as "not sent", never fails the day.
        cycleDay = try? c.decodeIfPresent(Int.self, forKey: .cycleDay)
        periodEndable = try? c.decodeIfPresent(Bool.self, forKey: .periodEndable)
        flow = try c.decodeIfPresent(String.self, forKey: .flow)
        hasSymptoms = try c.decodeIfPresent(Bool.self, forKey: .hasSymptoms) ?? false
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        basalBodyTempC = try c.decodeIfPresent(Double.self, forKey: .basalBodyTempC)
        temperatureExcluded = try c.decodeIfPresent(Bool.self, forKey: .temperatureExcluded) ?? false
        ovulationTest = try c.decodeIfPresent(String.self, forKey: .ovulationTest)
        cervicalMucus = try c.decodeIfPresent(String.self, forKey: .cervicalMucus)
        cervixPosition = try c.decodeIfPresent(String.self, forKey: .cervixPosition)
        cervixFirmness = try c.decodeIfPresent(String.self, forKey: .cervixFirmness)
        cervixOpening = try c.decodeIfPresent(String.self, forKey: .cervixOpening)
        // v1.39.1 — tolerant: a malformed value reads as "not logged", never fails the day.
        intermenstrualBleeding = (try? c.decodeIfPresent(Bool.self, forKey: .intermenstrualBleeding)) ?? false
        sexualActivity = (try? c.decodeIfPresent(Bool.self, forKey: .sexualActivity)) ?? false
        pregnancyTest = try? c.decodeIfPresent(String.self, forKey: .pregnancyTest)
        progesteroneTest = try? c.decodeIfPresent(String.self, forKey: .progesteroneTest)
        contraceptive = try? c.decodeIfPresent(String.self, forKey: .contraceptive)
        hasNote = (try? c.decodeIfPresent(Bool.self, forKey: .hasNote)) ?? false
    }
}

// MARK: - What the capture sheet may say about one date

/// #115 1.6 — the per-date claims the capture sheet makes, read off the
/// server's calendar grid (the web's `sheetDayContext`, `log-day-sheet.tsx` at
/// v1.39.0). The sheet used to offer "period ended" for every date and showed
/// no cycle day; both now come from the grid day for the CHOSEN date, never
/// from today's verdict and never from device arithmetic.
public struct CycleCaptureDayContext: Equatable, Sendable {
    /// The chosen date's own cycle day, or `nil` when the server gave none.
    public let cycleDay: Int?
    /// Whether "period ended" may be offered for the chosen date.
    public let offersPeriodEnd: Bool

    /// - A v1.39 grid day answers for itself.
    /// - A date a v1.39 grid does not hold (outside the loaded window) gets no
    ///   claims at all, as on the web: no cycle day, no period end.
    /// - A server older than v1.39 (no day carries `periodEndable`) or no grid
    ///   loaded yet keeps the earlier behaviour: both boundaries offered, no
    ///   cycle day shown.
    public init(date: String, days: [CalendarDayDTO]) {
        let day = days.last { $0.date == date }
        cycleDay = day?.cycleDay
        if let endable = day?.periodEndable {
            offersPeriodEnd = endable
        } else {
            offersPeriodEnd = !days.contains { $0.periodEndable != nil }
        }
    }
}
