import Foundation

// **LIFE (1.5.0, #132, Server #614) — the six answer shapes of the life
// circumstances.**
//
// Every object kind is `schema: 1` with a closed set of keys
// (`additionalProperties: false` in the v1.47.0 contract), and every question
// allows "no answer": `nil` for a single answer, an empty list for a multiple
// one. The encoders write `null` explicitly, because the server's schema lists
// every key as required.
//
// A value this build cannot read in full (another schema, an option it does
// not know) never decodes into one of these types: it becomes
// ``LifeFactValue/unsupported`` and is neither shown as an answer nor written
// over. That is the only way a newer client's answer survives an older app.

/// The one schema version this build reads and writes.
public enum LifeFactSchema {
    public static let current = 1
}

// MARK: - Year and month

/// A month of a year, wire form `YYYY-MM` (`quitMonth`). The contract asks for
/// the month and nothing finer, so the app never invents a day.
public struct LifeYearMonth: Hashable, Sendable, Codable, Comparable {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1 ... 12).contains(month), (1000 ... 9999).contains(year) else { return nil }
        self.year = year
        self.month = month
    }

    /// For values that are valid by construction (a calendar's own month).
    init(checkedYear year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// Parses exactly `^\d{4}-(0[1-9]|1[0-2])$`, the contract's pattern.
    public init?(wire: String) {
        let parts = wire.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        self.init(year: year, month: month)
    }

    /// The month a calendar date falls in, read in `calendar`'s time zone.
    public init?(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        self.init(year: year, month: month)
    }

    public var wire: String {
        String(format: "%04d-%02d", year, month)
    }

    /// The 15th of the month at noon in `calendar`'s zone: the anchor the month
    /// picker shows, far enough from both ends that no zone moves it.
    public func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = LifeYearMonth(wire: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not YYYY-MM"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wire)
    }

    public static func < (lhs: LifeYearMonth, rhs: LifeYearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

// MARK: - Option sets

public enum LifeTobaccoProduct: String, Codable, Sendable, CaseIterable, Hashable {
    case cigarettes
    case cigarsPipe = "cigars_pipe"
    case eCigarette = "e_cigarette"
    case heatedTobacco = "heated_tobacco"
    case snusPouches = "snus_pouches"
}

public enum LifeWorkSituation: String, Codable, Sendable, CaseIterable, Hashable {
    case none, indoor, outdoor, mixed
}

public enum LifeWorkPhysicalNature: String, Codable, Sendable, CaseIterable, Hashable {
    case mostlySitting = "mostly_sitting"
    case standingWalking = "standing_walking"
    case heavyPhysical = "heavy_physical"
}

public enum LifeWorkExposure: String, Codable, Sendable, CaseIterable, Hashable {
    case heat, cold, dust
    case fumesSolvents = "fumes_solvents"
    case noise
}

public enum LifeDietPattern: String, Codable, Sendable, CaseIterable, Hashable {
    case mixed, vegetarian, vegan, pescetarian, other
}

public enum LifeDietSpecific: String, Codable, Sendable, CaseIterable, Hashable {
    case intermittentFasting = "intermittent_fasting"
    case lowCarb = "low_carb"
    case prescribedDiet = "prescribed_diet"
}

public enum LifeLatestCaffeine: String, Codable, Sendable, CaseIterable, Hashable {
    case before12 = "before_12"
    case noonTo15 = "12_15"
    case afternoon15To18 = "15_18"
    case after18 = "after_18"
}

public enum LifeHealthGoal: String, Codable, Sendable, CaseIterable, Hashable {
    case weight
    case bloodPressure = "blood_pressure"
    case bloodSugar = "blood_sugar"
    case sleep, fitness
    case stressRecovery = "stress_recovery"
    case medicationRoutine = "medication_routine"
    case quitSmoking = "quit_smoking"
    case lessAlcohol = "less_alcohol"

    /// The server stores at most three goals.
    public static let maximum = 3
}

/// The ISO weekday of the contract: 1 = Monday … 7 = Sunday.
public enum LifeWeekday: Int, Codable, Sendable, CaseIterable, Hashable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

// MARK: - Shared decoding guard

private enum LifeSchemaKey: String, CodingKey {
    case schema
}

/// Throws unless the object carries `schema: 1`.
private func requireSchema(_ decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: LifeSchemaKey.self)
    let schema = try c.decode(Int.self, forKey: .schema)
    guard schema == LifeFactSchema.current else {
        throw DecodingError.dataCorruptedError(forKey: .schema, in: c, debugDescription: "schema \(schema)")
    }
}

// MARK: - TOBACCO_DETAIL

public struct LifeTobaccoDetail: Codable, Sendable, Hashable {
    public var products: [LifeTobaccoProduct]
    /// 1…100, only together with cigarettes.
    public var cigarettesPerDay: Int?
    /// 1900…this year.
    public var startYear: Int?
    /// Month precision, `YYYY-MM`. Asked only of a former smoker.
    public var quitMonth: LifeYearMonth?
    public var secondhandSmoke: Bool?

    public static let empty = LifeTobaccoDetail(
        products: [], cigarettesPerDay: nil, startYear: nil, quitMonth: nil, secondhandSmoke: nil
    )

    public static let cigarettesRange = 1 ... 100
    public static let earliestStartYear = 1900

    public init(
        products: [LifeTobaccoProduct],
        cigarettesPerDay: Int?,
        startYear: Int?,
        quitMonth: LifeYearMonth?,
        secondhandSmoke: Bool?
    ) {
        self.products = products
        self.cigarettesPerDay = cigarettesPerDay
        self.startYear = startYear
        self.quitMonth = quitMonth
        self.secondhandSmoke = secondhandSmoke
    }

    private enum CodingKeys: String, CodingKey {
        case schema, products, cigarettesPerDay, startYear, quitMonth, secondhandSmoke
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        products = try c.decode([LifeTobaccoProduct].self, forKey: .products)
        cigarettesPerDay = try c.decodeIfPresent(Int.self, forKey: .cigarettesPerDay)
        startYear = try c.decodeIfPresent(Int.self, forKey: .startYear)
        quitMonth = try c.decodeIfPresent(LifeYearMonth.self, forKey: .quitMonth)
        secondhandSmoke = try c.decodeIfPresent(Bool.self, forKey: .secondhandSmoke)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(products, forKey: .products)
        try c.encode(cigarettesPerDay, forKey: .cigarettesPerDay)
        try c.encode(startYear, forKey: .startYear)
        try c.encode(quitMonth, forKey: .quitMonth)
        try c.encode(secondhandSmoke, forKey: .secondhandSmoke)
    }

    public var isEmpty: Bool {
        products.isEmpty && cigarettesPerDay == nil && startYear == nil && quitMonth == nil && secondhandSmoke == nil
    }
}

// MARK: - ACTIVITY_HABIT

public struct LifeActivityHabit: Codable, Sendable, Hashable {
    /// 0…7
    public var moderateDaysPerWeek: Int?
    /// 0…600
    public var moderateMinutesPerDay: Int?
    /// 0…24 in half hours.
    public var sittingHoursWorkday: Double?

    public static let empty = LifeActivityHabit(
        moderateDaysPerWeek: nil, moderateMinutesPerDay: nil, sittingHoursWorkday: nil
    )

    public init(moderateDaysPerWeek: Int?, moderateMinutesPerDay: Int?, sittingHoursWorkday: Double?) {
        self.moderateDaysPerWeek = moderateDaysPerWeek
        self.moderateMinutesPerDay = moderateMinutesPerDay
        self.sittingHoursWorkday = sittingHoursWorkday
    }

    private enum CodingKeys: String, CodingKey {
        case schema, moderateDaysPerWeek, moderateMinutesPerDay, sittingHoursWorkday
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moderateDaysPerWeek = try c.decodeIfPresent(Int.self, forKey: .moderateDaysPerWeek)
        moderateMinutesPerDay = try c.decodeIfPresent(Int.self, forKey: .moderateMinutesPerDay)
        sittingHoursWorkday = try c.decodeIfPresent(Double.self, forKey: .sittingHoursWorkday)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(moderateDaysPerWeek, forKey: .moderateDaysPerWeek)
        try c.encode(moderateMinutesPerDay, forKey: .moderateMinutesPerDay)
        try c.encode(sittingHoursWorkday, forKey: .sittingHoursWorkday)
    }

    public var isEmpty: Bool {
        moderateDaysPerWeek == nil && moderateMinutesPerDay == nil && sittingHoursWorkday == nil
    }
}

// MARK: - WORK_CONTEXT

public struct LifeWorkContext: Codable, Sendable, Hashable {
    public var situation: LifeWorkSituation?
    public var physicalNature: LifeWorkPhysicalNature?
    /// Asked only with shift work.
    public var nightWork: Bool?
    public var exposures: [LifeWorkExposure]

    public static let empty = LifeWorkContext(situation: nil, physicalNature: nil, nightWork: nil, exposures: [])

    public init(
        situation: LifeWorkSituation?,
        physicalNature: LifeWorkPhysicalNature?,
        nightWork: Bool?,
        exposures: [LifeWorkExposure]
    ) {
        self.situation = situation
        self.physicalNature = physicalNature
        self.nightWork = nightWork
        self.exposures = exposures
    }

    private enum CodingKeys: String, CodingKey {
        case schema, situation, physicalNature, nightWork, exposures
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        situation = try c.decodeIfPresent(LifeWorkSituation.self, forKey: .situation)
        physicalNature = try c.decodeIfPresent(LifeWorkPhysicalNature.self, forKey: .physicalNature)
        nightWork = try c.decodeIfPresent(Bool.self, forKey: .nightWork)
        exposures = try c.decode([LifeWorkExposure].self, forKey: .exposures)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(situation, forKey: .situation)
        try c.encode(physicalNature, forKey: .physicalNature)
        try c.encode(nightWork, forKey: .nightWork)
        try c.encode(exposures, forKey: .exposures)
    }

    public var isEmpty: Bool {
        situation == nil && physicalNature == nil && nightWork == nil && exposures.isEmpty
    }
}

// MARK: - FREE_WEEKDAYS

public struct LifeFreeWeekdays: Codable, Sendable, Hashable {
    public var days: [LifeWeekday]

    public static let empty = LifeFreeWeekdays(days: [])

    public init(days: [LifeWeekday]) {
        self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case schema, days
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decode([LifeWeekday].self, forKey: .days)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(days.sorted { $0.rawValue < $1.rawValue }, forKey: .days)
    }

    public var isEmpty: Bool {
        days.isEmpty
    }
}

// MARK: - HABITS

public struct LifeHabits: Codable, Sendable, Hashable {
    public var napRegularly: Bool?
    public var snoringReported: Bool?
    public var dietPattern: LifeDietPattern?
    public var dietSpecifics: [LifeDietSpecific]
    /// 0…7
    public var lateMealsPerWeek: Int?
    /// 0…15
    public var fruitVegPortionsPerDay: Int?
    /// 0…20
    public var caffeineDrinksPerDay: Int?
    public var latestCaffeine: LifeLatestCaffeine?

    public static let empty = LifeHabits(
        napRegularly: nil, snoringReported: nil, dietPattern: nil, dietSpecifics: [],
        lateMealsPerWeek: nil, fruitVegPortionsPerDay: nil, caffeineDrinksPerDay: nil, latestCaffeine: nil
    )

    public init(
        napRegularly: Bool?,
        snoringReported: Bool?,
        dietPattern: LifeDietPattern?,
        dietSpecifics: [LifeDietSpecific],
        lateMealsPerWeek: Int?,
        fruitVegPortionsPerDay: Int?,
        caffeineDrinksPerDay: Int?,
        latestCaffeine: LifeLatestCaffeine?
    ) {
        self.napRegularly = napRegularly
        self.snoringReported = snoringReported
        self.dietPattern = dietPattern
        self.dietSpecifics = dietSpecifics
        self.lateMealsPerWeek = lateMealsPerWeek
        self.fruitVegPortionsPerDay = fruitVegPortionsPerDay
        self.caffeineDrinksPerDay = caffeineDrinksPerDay
        self.latestCaffeine = latestCaffeine
    }

    private enum CodingKeys: String, CodingKey {
        case schema, napRegularly, snoringReported, dietPattern, dietSpecifics
        case lateMealsPerWeek, fruitVegPortionsPerDay, caffeineDrinksPerDay, latestCaffeine
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        napRegularly = try c.decodeIfPresent(Bool.self, forKey: .napRegularly)
        snoringReported = try c.decodeIfPresent(Bool.self, forKey: .snoringReported)
        dietPattern = try c.decodeIfPresent(LifeDietPattern.self, forKey: .dietPattern)
        dietSpecifics = try c.decode([LifeDietSpecific].self, forKey: .dietSpecifics)
        lateMealsPerWeek = try c.decodeIfPresent(Int.self, forKey: .lateMealsPerWeek)
        fruitVegPortionsPerDay = try c.decodeIfPresent(Int.self, forKey: .fruitVegPortionsPerDay)
        caffeineDrinksPerDay = try c.decodeIfPresent(Int.self, forKey: .caffeineDrinksPerDay)
        latestCaffeine = try c.decodeIfPresent(LifeLatestCaffeine.self, forKey: .latestCaffeine)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(napRegularly, forKey: .napRegularly)
        try c.encode(snoringReported, forKey: .snoringReported)
        try c.encode(dietPattern, forKey: .dietPattern)
        try c.encode(dietSpecifics, forKey: .dietSpecifics)
        try c.encode(lateMealsPerWeek, forKey: .lateMealsPerWeek)
        try c.encode(fruitVegPortionsPerDay, forKey: .fruitVegPortionsPerDay)
        try c.encode(caffeineDrinksPerDay, forKey: .caffeineDrinksPerDay)
        try c.encode(latestCaffeine, forKey: .latestCaffeine)
    }

    public var isEmpty: Bool {
        napRegularly == nil && snoringReported == nil && dietPattern == nil && dietSpecifics.isEmpty
            && lateMealsPerWeek == nil && fruitVegPortionsPerDay == nil && caffeineDrinksPerDay == nil
            && latestCaffeine == nil
    }
}

// MARK: - HEALTH_GOALS

public struct LifeHealthGoals: Codable, Sendable, Hashable {
    public var goals: [LifeHealthGoal]

    public static let empty = LifeHealthGoals(goals: [])

    public init(goals: [LifeHealthGoal]) {
        self.goals = goals
    }

    private enum CodingKeys: String, CodingKey {
        case schema, goals
    }

    public init(from decoder: Decoder) throws {
        try requireSchema(decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goals = try c.decode([LifeHealthGoal].self, forKey: .goals)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LifeFactSchema.current, forKey: .schema)
        try c.encode(goals, forKey: .goals)
    }

    public var isEmpty: Bool {
        goals.isEmpty
    }
}
