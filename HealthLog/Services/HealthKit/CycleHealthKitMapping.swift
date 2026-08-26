import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// **Phase C2 — pure HealthKit ↔ cycle mapping.**
///
/// The 1:1 Swift mirror of the server's authoritative
/// `src/lib/cycle/healthkit-mapping.ts` (verified 2026-06-06). It is the single
/// source of truth for how an Apple Health reproductive-category sample folds
/// into a ``CycleDayLogWrite`` field set — and, in reverse, which HK category
/// type + value a MANUAL day-log writes back to (`CycleHealthKitWriter`).
///
/// **Foundation-pure where it can be** so the routing logic unit-tests without a
/// live `HKHealthStore`; the HealthKit-typed surfaces (category-value codepoints,
/// the read/write type sets) are `#if canImport(HealthKit)` + iOS-18-gated.
///
/// **Flow value source.** The contract (§5, Q3) mandates
/// `HKCategoryValueVaginalBleeding` (the iOS-18 reproductive type) with a legacy
/// `HKCategoryValueMenstrualFlow` fallback. Both map to the same contract flow
/// enum (`NONE|SPOTTING|LIGHT|MEDIUM|HEAVY`); `unspecified → LIGHT` (a logged-
/// but-unspecified bleeding day is at least light flow). `SPOTTING` has no HK
/// counterpart — it is only ever produced by a MANUAL entry, and on write-back a
/// `SPOTTING` day maps to HK `light` (the spotting↔light boundary per Q3).
///
/// Everything here stays dormant behind `FeatureFlag.cycleTracking` (the importer
/// + writer above it are only constructed when the gate passes).
enum CycleHealthKitMapping {
    // MARK: - HK category-type identifiers (server constants)

    static let menstrualFlow = "HKCategoryTypeIdentifierMenstrualFlow"
    static let intermenstrualBleeding = "HKCategoryTypeIdentifierIntermenstrualBleeding"
    static let cervicalMucus = "HKCategoryTypeIdentifierCervicalMucusQuality"
    static let ovulationTest = "HKCategoryTypeIdentifierOvulationTestResult"
    static let sexualActivity = "HKCategoryTypeIdentifierSexualActivity"
    static let pregnancyTest = "HKCategoryTypeIdentifierPregnancyTestResult"
    static let progesteroneTest = "HKCategoryTypeIdentifierProgesteroneTestResult"
    static let contraceptive = "HKCategoryTypeIdentifierContraceptive"
    static let pregnancy = "HKCategoryTypeIdentifierPregnancy"
    static let lactation = "HKCategoryTypeIdentifierLactation"

    /// The metadata key carrying the protection-used boolean on a
    /// SexualActivity sample.
    static let sexualActivityProtectionMeta = "HKMetadataKeySexualActivityProtectionUsed"

    // MARK: - Category-value lookup (integer codepoint → contract enum)

    /// `HKCategoryValueMenstrualFlow`: unspecified(1)/light(2)/medium(3)/
    /// heavy(4)/none(5). `unspecified → LIGHT` (conservative boundary).
    static func flow(forMenstrualFlowValue value: Int) -> CycleFlowLevel? {
        switch value {
        case 1: .light // unspecified
        case 2: .light
        case 3: .medium
        case 4: .heavy
        case 5: CycleFlowLevel.none // HK `none` → NONE (NOT Optional.none)
        default: nil
        }
    }

    /// `HKCategoryValueVaginalBleeding` (iOS 18): unspecified(1)/light(2)/
    /// medium(3)/heavy(4)/none(5). Identical codepoint layout to the legacy
    /// menstrual-flow values, so the same table applies.
    static func flow(forVaginalBleedingValue value: Int) -> CycleFlowLevel? {
        flow(forMenstrualFlowValue: value)
    }

    /// `HKCategoryValueOvulationTestResult`: negative(1)/LHsurge(2)/
    /// indeterminate(3)/estrogenSurge(4).
    static func ovulationTest(forValue value: Int) -> CycleOvulationTest? {
        switch value {
        case 1: .negative
        case 2: .positiveLHSurge
        case 3: .indeterminate
        case 4: .estrogenSurge
        default: nil
        }
    }

    /// `HKCategoryValueCervicalMucusQuality`: dry(1)/sticky(2)/creamy(3)/
    /// watery(4)/eggWhite(5).
    static func cervicalMucus(forValue value: Int) -> CycleCervicalMucus? {
        switch value {
        case 1: .dry
        case 2: .sticky
        case 3: .creamy
        case 4: .watery
        case 5: .eggWhite
        default: nil
        }
    }

    /// Shared home-test enum for pregnancy + progesterone:
    /// negative(1)/positive(2)/indeterminate(3).
    static func homeTest(forValue value: Int) -> CycleTestResult? {
        switch value {
        case 1: .negative
        case 2: .positive
        case 3: .indeterminate
        default: nil
        }
    }

    /// `HKCategoryValueContraceptive`: unspecified(1)/implant(2)/injection(3)/
    /// intrauterineDevice(4)/intravaginalRing(5)/oral(6)/patch(7)/emergency(8).
    /// 1:1 mirror of the server's `HK_CONTRACEPTIVE_VALUES` table.
    static func contraceptive(forValue value: Int) -> CycleContraceptiveKind? {
        switch value {
        case 1: .unspecified
        case 2: .implant
        case 3: .injection
        case 4: .iud
        case 5: .intravaginalRing
        case 6: .oral
        case 7: .patch
        case 8: .emergency
        default: nil
        }
    }

    // MARK: - Symptom catalogue (HK identifier → seeded CycleSymptom.key)

    /// One HK identifier per canonical symptom key (migration 0129 catalogue).
    /// Identifiers without a seeded counterpart are omitted — they fall through
    /// to `skip` rather than inventing a catalogue row.
    static let symptomKeyByIdentifier: [String: String] = [
        "HKCategoryTypeIdentifierAbdominalCramps": "cramps",
        "HKCategoryTypeIdentifierHeadache": "headache",
        "HKCategoryTypeIdentifierBloating": "bloating",
        "HKCategoryTypeIdentifierAcne": "acne",
        "HKCategoryTypeIdentifierBreastPain": "breast_tenderness",
        "HKCategoryTypeIdentifierFatigue": "fatigue",
        "HKCategoryTypeIdentifierLowerBackPain": "back_pain",
        "HKCategoryTypeIdentifierSleepChanges": "insomnia",
        "HKCategoryTypeIdentifierMoodChanges": "mood_swings",
        "HKCategoryTypeIdentifierAppetiteChanges": "food_cravings",
        "HKCategoryTypeIdentifierNausea": "nausea"
    ]

    /// HK severity codepoints: notPresent(1)/present(2)/mild(3)/moderate(4)/
    /// severe(5). A `notPresent` sample is an explicit "I did not have this" —
    /// it must NOT create a symptom link. `nil` value = present, no severity.
    static func symptomIsPresent(rawValue: Int?) -> Bool {
        guard let rawValue else { return true }
        return rawValue != 1
    }

    /// HK severity codepoint → contract severity (1...4) for a present sample.
    /// `present`(2) with no graded severity → nil (server stores key-only).
    /// mild(3)→1, moderate(4)→2, severe(5)→3; the contract band is 1..4 so we
    /// keep room for an unlogged top bucket but never emit 0.
    static func symptomSeverity(rawValue: Int?) -> Int? {
        switch rawValue {
        case 3: 1 // mild
        case 4: 2 // moderate
        case 5: 3 // severe
        default: nil // present(2)/nil — key only
        }
    }

    // MARK: - Routed output

    /// A partial ``CycleDayLogWrite`` field set one HK sample fills.
    struct DayLogFields: Equatable {
        var flow: CycleFlowLevel?
        var intermenstrualBleeding: Bool?
        var ovulationTest: CycleOvulationTest?
        var cervicalMucus: CycleCervicalMucus?
        var sexualActivity: Bool?
        var protectedSex: Bool?
        var pregnancyTest: CycleTestResult?
        var progesteroneTest: CycleTestResult?
        /// v0.14.8 — the active contraceptive method, recorded on the day-log
        /// timeline (the write contract surfaced the field in v1.16.x).
        var contraceptive: CycleContraceptiveKind?
        /// Seeded symptom catalogue key + optional severity to link on the day.
        var symptom: CycleSymptomDTO?
    }

    /// The routed destination of one inbound HK reproductive sample.
    enum Route: Equatable {
        /// Fold the fields into the day's day-log (the common case).
        case dayLog(DayLogFields)
        /// No cycle destination (unrecognised value, deferred pregnancy-mode,
        /// or an explicit not-present symptom).
        case skip
    }

    /// Every HK identifier this module routes (day-log + symptoms). Excludes the
    /// STATUS-only `pregnancy`/`lactation` (deferred) and `basalBodyTemperature`
    /// (a quantity sample handled by the measurements + BBT-mirror path).
    static var routedIdentifiers: Set<String> {
        var set: Set<String> = [
            menstrualFlow, intermenstrualBleeding, cervicalMucus, ovulationTest,
            sexualActivity, pregnancyTest, progesteroneTest, contraceptive
        ]
        set.formUnion(symptomKeyByIdentifier.keys)
        return set
    }

    /// Does this module own the inbound identifier?
    static func isCycleIdentifier(_ identifier: String) -> Bool {
        routedIdentifiers.contains(identifier)
    }

    /// Map one inbound HK reproductive sample to its cycle destination — the 1:1
    /// mirror of the server's `mapHkCycleSample`.
    ///
    /// - Parameters:
    ///   - identifier: the `HKCategoryTypeIdentifier…` string.
    ///   - value: the sample's integer codepoint, `nil` for presence-only.
    ///   - protectionUsed: resolved protection metadata for a SexualActivity
    ///     sample (`nil` when absent → `protectedSex` left unset).
    static func route(
        identifier: String,
        value: Int?,
        protectionUsed: Bool? = nil
    ) -> Route {
        // Symptom category types → catalogue key (skip an explicit not-present).
        if let key = symptomKeyByIdentifier[identifier] {
            guard symptomIsPresent(rawValue: value) else { return .skip }
            return .dayLog(DayLogFields(symptom: CycleSymptomDTO(key: key, severity: symptomSeverity(rawValue: value))))
        }

        switch identifier {
        case intermenstrualBleeding:
            // A present sample asserts spotting outside the period window.
            return .dayLog(DayLogFields(intermenstrualBleeding: true))
        case sexualActivity:
            return .dayLog(DayLogFields(sexualActivity: true, protectedSex: protectionUsed))
        case menstrualFlow, cervicalMucus, ovulationTest, pregnancyTest, progesteroneTest:
            return routeValueBearing(identifier: identifier, value: value)
        case contraceptive:
            return routeContraceptive(value: value)
        default:
            // pregnancy / lactation status carry no v1.15.0 day-log destination.
            return .skip
        }
    }

    /// The value-bearing enum branches of ``route`` (flow / mucus / ovulation /
    /// pregnancy / progesterone / contraceptive) — split out so `route` stays
    /// under the cyclomatic-complexity budget.
    private static func routeValueBearing(identifier: String, value: Int?) -> Route {
        switch identifier {
        case menstrualFlow:
            guard let value, let flow = flow(forMenstrualFlowValue: value) else { return .skip }
            return .dayLog(DayLogFields(flow: flow))
        case cervicalMucus:
            guard let value, let mucus = cervicalMucus(forValue: value) else { return .skip }
            return .dayLog(DayLogFields(cervicalMucus: mucus))
        case ovulationTest:
            guard let value, let test = ovulationTest(forValue: value) else { return .skip }
            return .dayLog(DayLogFields(ovulationTest: test))
        case pregnancyTest:
            guard let value, let test = homeTest(forValue: value) else { return .skip }
            return .dayLog(DayLogFields(pregnancyTest: test))
        case progesteroneTest:
            guard let value, let test = homeTest(forValue: value) else { return .skip }
            return .dayLog(DayLogFields(progesteroneTest: test))
        default:
            return .skip
        }
    }

    /// The contraceptive branch of ``route`` — its own helper so neither
    /// `route` nor `routeValueBearing` breaches the complexity budget.
    ///
    /// v0.14.8 — the v1.16.x write contract surfaced `contraceptive` on the
    /// day-log input, so the method now lands on the timeline (the half of the
    /// former 2026-06-20 TODO this module can own). The server-side
    /// counterpart — nudging a still-default GENERAL_HEALTH profile goal to
    /// AVOID_PREGNANCY — is an intent-revealing, audit-logged mutation the
    /// server applies on its export.xml import path (`import-accumulator.ts`)
    /// but not yet on the live bulk route; replicating it client-side would
    /// bypass the server's audit trail.
    private static func routeContraceptive(value: Int?) -> Route {
        // TODO(owner:maintainer, date:2026-07-15, gh:#27): ask the server repo to
        // apply the same goal-nudge on `/api/cycle/day-logs/bulk` (ios-coord),
        // then verify the live-HK path end-to-end.
        guard let value, let kind = contraceptive(forValue: value) else { return .skip }
        return .dayLog(DayLogFields(contraceptive: kind))
    }

    // MARK: - Reverse map (MANUAL day-log → HK write-back)

    /// `CycleFlowLevel` → `HKCategoryValueVaginalBleeding`/`MenstrualFlow`
    /// codepoint. `SPOTTING → light(2)` (the spotting↔light boundary, Q3) —
    /// HK has no spotting value. `NONE → none(5)`.
    static func vaginalBleedingValue(for flow: CycleFlowLevel) -> Int {
        switch flow {
        case .none: 5
        case .spotting: 2 // SPOTTING ↔ HK light
        case .light: 2
        case .medium: 3
        case .heavy: 4
        }
    }

    static func ovulationTestValue(for test: CycleOvulationTest) -> Int {
        switch test {
        case .negative: 1
        case .positiveLHSurge: 2
        case .indeterminate: 3
        case .estrogenSurge: 4
        }
    }

    static func cervicalMucusValue(for mucus: CycleCervicalMucus) -> Int {
        switch mucus {
        case .dry: 1
        case .sticky: 2
        case .creamy: 3
        case .watery: 4
        case .eggWhite: 5
        }
    }

    static func homeTestValue(for result: CycleTestResult) -> Int {
        switch result {
        case .negative: 1
        case .positive: 2
        case .indeterminate: 3
        }
    }

    static func symptomIdentifier(forKey key: String) -> String? {
        symptomKeyByIdentifier.first(where: { $0.value == key })?.key
    }

    // MARK: - Write-back value validation (SDK-verified ranges)

    /// Which HK value enum a symptom category type accepts. Verified against the
    /// iOS 26.5 SDK `HKTypeIdentifiers.h` annotations (2026-06-11): writing a
    /// codepoint outside the type's enum raises an uncatchable
    /// `NSInvalidArgumentException` in `HKCategorySample` `_validateForCreation`.
    enum SymptomValueKind: Equatable {
        /// `HKCategoryValueSeverity`: unspecified(0)/notPresent(1)/mild(2)/
        /// moderate(3)/severe(4).
        case severity
        /// `HKCategoryValuePresence`: present(0)/notPresent(1).
        case presence
        /// `HKCategoryValueAppetiteChanges`: unspecified(0)/noChange(1)/
        /// decreased(2)/increased(3).
        case appetiteChanges
    }

    /// SDK-verified value kind per routed symptom identifier. Anything not in
    /// this table has no known-safe write codepoint and must be skipped.
    static let symptomValueKindByIdentifier: [String: SymptomValueKind] = [
        "HKCategoryTypeIdentifierAbdominalCramps": .severity,
        "HKCategoryTypeIdentifierHeadache": .severity,
        "HKCategoryTypeIdentifierBloating": .severity,
        "HKCategoryTypeIdentifierAcne": .severity,
        "HKCategoryTypeIdentifierBreastPain": .severity,
        "HKCategoryTypeIdentifierFatigue": .severity,
        "HKCategoryTypeIdentifierLowerBackPain": .severity,
        "HKCategoryTypeIdentifierSleepChanges": .presence,
        "HKCategoryTypeIdentifierMoodChanges": .presence,
        "HKCategoryTypeIdentifierAppetiteChanges": .appetiteChanges,
        "HKCategoryTypeIdentifierNausea": .severity
    ]

    /// Contract symptom severity (1...4 or nil) → the valid HK codepoint for the
    /// identifier's value enum. `nil` when the identifier is unknown or the
    /// severity falls outside the contract band — the caller skips the sample
    /// (never writes garbage, never crashes).
    ///
    /// - Severity types: nil → unspecified(0) (logged, no graded severity — what
    ///   the Health app writes for a plain symptom tap); 1→mild(2), 2→moderate(3),
    ///   3→severe(4); 4 (contract top bucket) clamps to severe(4).
    /// - Presence types can't express severity → always present(0).
    /// - `AppetiteChanges` (food_cravings) → increased(3).
    static func hkSymptomWriteValue(identifier: String, severity: Int?) -> Int? {
        guard let kind = symptomValueKindByIdentifier[identifier] else { return nil }
        switch kind {
        case .presence:
            return 0 // present
        case .appetiteChanges:
            return 3 // food_cravings ↔ increased appetite
        case .severity:
            switch severity {
            case nil: return 0 // unspecified — logged without graded severity
            case 1?: return 2 // mild
            case 2?: return 3 // moderate
            case 3?: return 4 // severe
            case 4?: return 4 // contract top bucket → clamp to severe
            default: return nil // out of contract band — skip
            }
        }
    }

    /// The closed range of category values HealthKit accepts for one of our
    /// write-back identifiers (defense-in-depth gate before `HKCategorySample`
    /// init — an out-of-range value raises an uncatchable ObjC exception).
    /// `nil` for identifiers we never write.
    static func validWriteValueRange(forIdentifier identifier: String) -> ClosedRange<Int>? {
        if let kind = symptomValueKindByIdentifier[identifier] {
            switch kind {
            case .severity: return 0 ... 4
            case .presence: return 0 ... 1
            case .appetiteChanges: return 0 ... 3
            }
        }
        switch identifier {
        case menstrualFlow: return 1 ... 5 // HKCategoryValueVaginalBleeding
        case intermenstrualBleeding, sexualActivity: return 0 ... 0 // notApplicable only
        case cervicalMucus: return 1 ... 5
        case ovulationTest: return 1 ... 4
        case pregnancyTest, progesteroneTest: return 1 ... 3
        default: return nil
        }
    }
}
