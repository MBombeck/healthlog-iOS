import Foundation

/// **LIFE (1.5.0)** — the catalog wording of every option and section.
///
/// Every key is written out (no key built at runtime), so the catalog checks
/// see each one, and the wording follows the server's `records.life.*`
/// messages of v1.46.6 word for word. Derived and screening texts are
/// medical keys: outside German they are `needs_review`.
enum LifeCopy {
    static func title(_ key: LifeSectionKey) -> String {
        switch key {
        case .tobacco: String(localized: "life.section.tobacco")
        case .alcohol: String(localized: "life.section.alcohol")
        case .activity: String(localized: "life.section.activity")
        case .work: String(localized: "life.section.work")
        case .habits: String(localized: "life.section.habits")
        case .goals: String(localized: "life.section.goals")
        }
    }

    static func symbol(_ key: LifeSectionKey) -> String {
        switch key {
        case .tobacco: "smoke.fill"
        case .alcohol: "wineglass.fill"
        case .activity: "figure.walk"
        case .work: "briefcase.fill"
        case .habits: "bed.double.fill"
        case .goals: "target"
        }
    }

    static func smoking(_ value: AnamnesisFactValue) -> String {
        switch value {
        case .never: String(localized: "life.value.smoking.never")
        case .former: String(localized: "life.value.smoking.former")
        case .current: String(localized: "life.value.smoking.current")
        default: String(localized: "anamnesis.value.unknown")
        }
    }

    static func shift(_ value: AnamnesisFactValue) -> String {
        switch value {
        case .declaredNone: String(localized: "life.value.shift.none")
        case .fixedShift: String(localized: "life.value.shift.fixed")
        case .rotating: String(localized: "life.value.shift.rotating")
        default: String(localized: "anamnesis.value.unknown")
        }
    }

    static func product(_ value: LifeTobaccoProduct) -> String {
        switch value {
        case .cigarettes: String(localized: "life.value.product.cigarettes")
        case .cigarsPipe: String(localized: "life.value.product.cigarsPipe")
        case .eCigarette: String(localized: "life.value.product.eCigarette")
        case .heatedTobacco: String(localized: "life.value.product.heatedTobacco")
        case .snusPouches: String(localized: "life.value.product.snusPouches")
        }
    }

    static func situation(_ value: LifeWorkSituation) -> String {
        switch value {
        case .none: String(localized: "life.value.situation.none")
        case .indoor: String(localized: "life.value.situation.indoor")
        case .outdoor: String(localized: "life.value.situation.outdoor")
        case .mixed: String(localized: "life.value.situation.mixed")
        }
    }

    static func physicalNature(_ value: LifeWorkPhysicalNature) -> String {
        switch value {
        case .mostlySitting: String(localized: "life.value.nature.mostlySitting")
        case .standingWalking: String(localized: "life.value.nature.standingWalking")
        case .heavyPhysical: String(localized: "life.value.nature.heavyPhysical")
        }
    }

    static func exposure(_ value: LifeWorkExposure) -> String {
        switch value {
        case .heat: String(localized: "life.value.exposure.heat")
        case .cold: String(localized: "life.value.exposure.cold")
        case .dust: String(localized: "life.value.exposure.dust")
        case .fumesSolvents: String(localized: "life.value.exposure.fumesSolvents")
        case .noise: String(localized: "life.value.exposure.noise")
        }
    }

    static func weekday(_ value: LifeWeekday) -> String {
        switch value {
        case .monday: String(localized: "life.value.weekday.1")
        case .tuesday: String(localized: "life.value.weekday.2")
        case .wednesday: String(localized: "life.value.weekday.3")
        case .thursday: String(localized: "life.value.weekday.4")
        case .friday: String(localized: "life.value.weekday.5")
        case .saturday: String(localized: "life.value.weekday.6")
        case .sunday: String(localized: "life.value.weekday.7")
        }
    }

    static func diet(_ value: LifeDietPattern) -> String {
        switch value {
        case .mixed: String(localized: "life.value.diet.mixed")
        case .vegetarian: String(localized: "life.value.diet.vegetarian")
        case .vegan: String(localized: "life.value.diet.vegan")
        case .pescetarian: String(localized: "life.value.diet.pescetarian")
        case .other: String(localized: "life.value.diet.other")
        }
    }

    static func dietSpecific(_ value: LifeDietSpecific) -> String {
        switch value {
        case .intermittentFasting: String(localized: "life.value.dietSpecific.intermittentFasting")
        case .lowCarb: String(localized: "life.value.dietSpecific.lowCarb")
        case .prescribedDiet: String(localized: "life.value.dietSpecific.prescribedDiet")
        }
    }

    static func caffeine(_ value: LifeLatestCaffeine) -> String {
        switch value {
        case .before12: String(localized: "life.value.caffeine.before12")
        case .noonTo15: String(localized: "life.value.caffeine.12to15")
        case .afternoon15To18: String(localized: "life.value.caffeine.15to18")
        case .after18: String(localized: "life.value.caffeine.after18")
        }
    }

    static func goal(_ value: LifeHealthGoal) -> String {
        switch value {
        case .weight: String(localized: "life.value.goal.weight")
        case .bloodPressure: String(localized: "life.value.goal.bloodPressure")
        case .bloodSugar: String(localized: "life.value.goal.bloodSugar")
        case .sleep: String(localized: "life.value.goal.sleep")
        case .fitness: String(localized: "life.value.goal.fitness")
        case .stressRecovery: String(localized: "life.value.goal.stressRecovery")
        case .medicationRoutine: String(localized: "life.value.goal.medicationRoutine")
        case .quitSmoking: String(localized: "life.value.goal.quitSmoking")
        case .lessAlcohol: String(localized: "life.value.goal.lessAlcohol")
        }
    }

    // MARK: - Screening hints (medical)

    static func screeningTitle(_ id: LifeDerived.ScreeningHint.HintID) -> String {
        switch id {
        case .lungLowDoseCT: String(localized: "life.screening.title.lungLowDoseCT")
        case .aaaUltrasound: String(localized: "life.screening.title.aaaUltrasound")
        }
    }

    static func screeningStatus(_ status: LifeDerived.ScreeningHint.Status) -> String {
        switch status {
        case .suggested: String(localized: "life.screening.status.suggested")
        case .notEligible: String(localized: "life.screening.status.notEligible")
        case .unknown: String(localized: "life.screening.status.unknown")
        }
    }

    /// The server's sentence for a reason key, or `nil` for a key this build
    /// has no wording for (never a sentence of our own).
    static func screeningReason(_ key: String) -> String? {
        screeningReasons[key].map { String(localized: $0) }
    }

    private static let screeningReasons: [String: String.LocalizationValue] = [
        "never_smoked": "life.screening.reason.neverSmoked",
        "missing_birth_date": "life.screening.reason.missingBirthDate",
        "age_out_of_range": "life.screening.reason.ageOutOfRange",
        "missing_smoking_status": "life.screening.reason.missingSmokingStatus",
        "no_cigarettes": "life.screening.reason.noCigarettes",
        "missing_smoking_history": "life.screening.reason.missingSmokingHistory",
        "pack_years_below_15": "life.screening.reason.packYearsBelow15",
        "pack_years_below_20": "life.screening.reason.packYearsBelow20",
        "smoked_years_below_25": "life.screening.reason.smokedYearsBelow25",
        "missing_quit_date": "life.screening.reason.missingQuitDate",
        "quit_over_10_years": "life.screening.reason.quitOver10Years",
        "quit_over_15_years": "life.screening.reason.quitOver15Years",
        "missing_sex": "life.screening.reason.missingSex",
        "sex_not_male": "life.screening.reason.sexNotMale"
    ]
}
