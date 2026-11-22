import Foundation

// Generated from the server vocabularies (`src/lib/seizures/shared.ts`,
// `src/lib/seizures/ilae.ts`) and the web's labels (`messages/*.json`,
// `seizures.*`), so the app and the web name every value the same way.
// Each enum decodes a word this build does not know to `.unrecognized`.

/// Whether it was a seizure or only suspected.
public enum SeizureCertainty: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case confirmed = "CONFIRMED"
    case suspected = "SUSPECTED"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureCertainty.unrecognized
    public static let wireVocabulary: StaticString = "seizure certainty"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureCertainty] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .confirmed: String(localized: "seizures.certainty.CONFIRMED")
        case .suspected: String(localized: "seizures.certainty.SUSPECTED")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// Awake, asleep or on waking.
public enum SeizureSleepState: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case awake = "AWAKE"
    case asleep = "ASLEEP"
    case onWaking = "ON_WAKING"
    case unknown = "UNKNOWN"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureSleepState.unrecognized
    public static let wireVocabulary: StaticString = "seizure sleepState"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureSleepState] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .awake: String(localized: "seizures.sleepState.AWAKE")
        case .asleep: String(localized: "seizures.sleepState.ASLEEP")
        case .onWaking: String(localized: "seizures.sleepState.ON_WAKING")
        case .unknown: String(localized: "seizures.sleepState.UNKNOWN")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// How the duration came about.
public enum SeizureDurationSource: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case timed = "TIMED"
    case estimated = "ESTIMATED"
    case unknown = "UNKNOWN"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureDurationSource.unrecognized
    public static let wireVocabulary: StaticString = "seizure durationSource"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureDurationSource] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .timed: String(localized: "seizures.durationSource.TIMED")
        case .estimated: String(localized: "seizures.durationSource.ESTIMATED")
        case .unknown: String(localized: "seizures.durationSource.UNKNOWN")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// How sure the start time is.
public enum SeizureOnsetPrecision: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case exact = "EXACT"
    case approx = "APPROX"
    case unknownTime = "UNKNOWN_TIME"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureOnsetPrecision.unrecognized
    public static let wireVocabulary: StaticString = "seizure onsetPrecision"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureOnsetPrecision] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .exact: String(localized: "seizures.onsetPrecision.EXACT")
        case .approx: String(localized: "seizures.onsetPrecision.APPROX")
        case .unknownTime: String(localized: "seizures.onsetPrecision.UNKNOWN_TIME")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// The emergency care that followed.
public enum SeizureEmergency: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case noneNoted = "NONE"
    case emsCalled = "EMS_CALLED"
    case edVisit = "ED_VISIT"
    case admitted = "ADMITTED"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureEmergency.unrecognized
    public static let wireVocabulary: StaticString = "seizure emergency"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureEmergency] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .noneNoted: String(localized: "seizures.emergency.NONE")
        case .emsCalled: String(localized: "seizures.emergency.EMS_CALLED")
        case .edVisit: String(localized: "seizures.emergency.ED_VISIT")
        case .admitted: String(localized: "seizures.emergency.ADMITTED")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// How a rescue dose was given.
public enum SeizureRescueRoute: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case buccal = "BUCCAL"
    case intranasal = "INTRANASAL"
    case rectal = "RECTAL"
    case oral = "ORAL"
    case sublingual = "SUBLINGUAL"
    case im = "IM"
    case ivByEms = "IV_BY_EMS"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureRescueRoute.unrecognized
    public static let wireVocabulary: StaticString = "seizure route"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureRescueRoute] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .buccal: String(localized: "seizures.route.BUCCAL")
        case .intranasal: String(localized: "seizures.route.INTRANASAL")
        case .rectal: String(localized: "seizures.route.RECTAL")
        case .oral: String(localized: "seizures.route.ORAL")
        case .sublingual: String(localized: "seizures.route.SUBLINGUAL")
        case .im: String(localized: "seizures.route.IM")
        case .ivByEms: String(localized: "seizures.route.IV_BY_EMS")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// What a rescue dose did.
public enum SeizureRescueEffect: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case stopped = "STOPPED"
    case reduced = "REDUCED"
    case noEffect = "NO_EFFECT"
    case unknown = "UNKNOWN"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureRescueEffect.unrecognized
    public static let wireVocabulary: StaticString = "seizure effect"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureRescueEffect] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .stopped: String(localized: "seizures.effect.STOPPED")
        case .reduced: String(localized: "seizures.effect.REDUCED")
        case .noEffect: String(localized: "seizures.effect.NO_EFFECT")
        case .unknown: String(localized: "seizures.effect.UNKNOWN")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// Who saw it or gave a dose.
public enum SeizureObserverRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case selfReported = "SELF"
    case parent = "PARENT"
    case partner = "PARTNER"
    case family = "FAMILY"
    case carer = "CARER"
    case teacher = "TEACHER"
    case clinician = "CLINICIAN"
    case paramedic = "PARAMEDIC"
    case other = "OTHER"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureObserverRole.unrecognized
    public static let wireVocabulary: StaticString = "seizure observer"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureObserverRole] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .selfReported: String(localized: "seizures.observer.SELF")
        case .parent: String(localized: "seizures.observer.PARENT")
        case .partner: String(localized: "seizures.observer.PARTNER")
        case .family: String(localized: "seizures.observer.FAMILY")
        case .carer: String(localized: "seizures.observer.CARER")
        case .teacher: String(localized: "seizures.observer.TEACHER")
        case .clinician: String(localized: "seizures.observer.CLINICIAN")
        case .paramedic: String(localized: "seizures.observer.PARAMEDIC")
        case .other: String(localized: "seizures.observer.OTHER")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// A suspected trigger, the person's own guess.
public enum SeizureTrigger: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case missedDose = "MISSED_DOSE"
    case sleepDeprivation = "SLEEP_DEPRIVATION"
    case fever = "FEVER"
    case illness = "ILLNESS"
    case menstruation = "MENSTRUATION"
    case alcohol = "ALCOHOL"
    case flashingLights = "FLASHING_LIGHTS"
    case stress = "STRESS"
    case other = "OTHER"
    case noneIdentified = "NONE_IDENTIFIED"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureTrigger.unrecognized
    public static let wireVocabulary: StaticString = "seizure trigger"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureTrigger] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .missedDose: String(localized: "seizures.trigger.MISSED_DOSE")
        case .sleepDeprivation: String(localized: "seizures.trigger.SLEEP_DEPRIVATION")
        case .fever: String(localized: "seizures.trigger.FEVER")
        case .illness: String(localized: "seizures.trigger.ILLNESS")
        case .menstruation: String(localized: "seizures.trigger.MENSTRUATION")
        case .alcohol: String(localized: "seizures.trigger.ALCOHOL")
        case .flashingLights: String(localized: "seizures.trigger.FLASHING_LIGHTS")
        case .stress: String(localized: "seizures.trigger.STRESS")
        case .other: String(localized: "seizures.trigger.OTHER")
        case .noneIdentified: String(localized: "seizures.trigger.NONE_IDENTIFIED")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// An injury during the seizure.
public enum SeizureInjury: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case noneNoted = "NONE"
    case tongueBite = "TONGUE_BITE"
    case head = "HEAD"
    case fallOther = "FALL_OTHER"
    case burn = "BURN"
    case fracture = "FRACTURE"
    case other = "OTHER"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureInjury.unrecognized
    public static let wireVocabulary: StaticString = "seizure injury"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureInjury] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .noneNoted: String(localized: "seizures.injury.NONE")
        case .tongueBite: String(localized: "seizures.injury.TONGUE_BITE")
        case .head: String(localized: "seizures.injury.HEAD")
        case .fallOther: String(localized: "seizures.injury.FALL_OTHER")
        case .burn: String(localized: "seizures.injury.BURN")
        case .fracture: String(localized: "seizures.injury.FRACTURE")
        case .other: String(localized: "seizures.injury.OTHER")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// What followed the seizure.
public enum SeizurePostictal: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case sleep = "SLEEP"
    case confusion = "CONFUSION"
    case headache = "HEADACHE"
    case weaknessTodd = "WEAKNESS_TODD"
    case speech = "SPEECH"
    case agitation = "AGITATION"
    case other = "OTHER"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizurePostictal.unrecognized
    public static let wireVocabulary: StaticString = "seizure postictal"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizurePostictal] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .sleep: String(localized: "seizures.postictal.SLEEP")
        case .confusion: String(localized: "seizures.postictal.CONFUSION")
        case .headache: String(localized: "seizures.postictal.HEADACHE")
        case .weaknessTodd: String(localized: "seizures.postictal.WEAKNESS_TODD")
        case .speech: String(localized: "seizures.postictal.SPEECH")
        case .agitation: String(localized: "seizures.postictal.AGITATION")
        case .other: String(localized: "seizures.postictal.OTHER")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// What was seen, in order.
public enum SeizureSemiology: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case aura = "AURA"
    case behaviourArrest = "BEHAVIOUR_ARREST"
    case staring = "STARING"
    case automatisms = "AUTOMATISMS"
    case tonic = "TONIC"
    case clonic = "CLONIC"
    case myoclonic = "MYOCLONIC"
    case atonicDrop = "ATONIC_DROP"
    case spasms = "SPASMS"
    case headEyeVersion = "HEAD_EYE_VERSION"
    case vocalisation = "VOCALISATION"
    case cyanosis = "CYANOSIS"
    case drooling = "DROOLING"
    case breathingChange = "BREATHING_CHANGE"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureSemiology.unrecognized
    public static let wireVocabulary: StaticString = "seizure semiology"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureSemiology] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .aura: String(localized: "seizures.semiology.AURA")
        case .behaviourArrest: String(localized: "seizures.semiology.BEHAVIOUR_ARREST")
        case .staring: String(localized: "seizures.semiology.STARING")
        case .automatisms: String(localized: "seizures.semiology.AUTOMATISMS")
        case .tonic: String(localized: "seizures.semiology.TONIC")
        case .clonic: String(localized: "seizures.semiology.CLONIC")
        case .myoclonic: String(localized: "seizures.semiology.MYOCLONIC")
        case .atonicDrop: String(localized: "seizures.semiology.ATONIC_DROP")
        case .spasms: String(localized: "seizures.semiology.SPASMS")
        case .headEyeVersion: String(localized: "seizures.semiology.HEAD_EYE_VERSION")
        case .vocalisation: String(localized: "seizures.semiology.VOCALISATION")
        case .cyanosis: String(localized: "seizures.semiology.CYANOSIS")
        case .drooling: String(localized: "seizures.semiology.DROOLING")
        case .breathingChange: String(localized: "seizures.semiology.BREATHING_CHANGE")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// The four ILAE 2025 classes, in picker order.
public enum SeizureIlaeClass: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case focal = "FOCAL"
    case generalized = "GENERALIZED"
    case unknown = "UNKNOWN"
    case unclassified = "UNCLASSIFIED"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureIlaeClass.unrecognized
    public static let wireVocabulary: StaticString = "seizure ilaeClass"

    /// The values a person can choose, in the server's order.
    public static var choices: [SeizureIlaeClass] {
        allCases.filter { $0 != .unrecognized }
    }

    public var label: String {
        switch self {
        case .focal: String(localized: "seizures.ilaeClass.FOCAL")
        case .generalized: String(localized: "seizures.ilaeClass.GENERALIZED")
        case .unknown: String(localized: "seizures.ilaeClass.UNKNOWN")
        case .unclassified: String(localized: "seizures.ilaeClass.UNCLASSIFIED")
        case .unrecognized: String(localized: "seizures.notRecorded")
        }
    }
}

/// The ILAE 2025 seizure type (`SEIZURE_ILAE_TYPES`). The `*_UNDETERMINED`
/// values record the parent class when the next level is not known.
public enum SeizureIlaeType: String, Codable, Sendable, Equatable, Hashable, CaseIterable, TolerantServerEnum {
    case focalPreserved = "FOCAL_PRESERVED"
    case focalImpaired = "FOCAL_IMPAIRED"
    case focalUndetermined = "FOCAL_UNDETERMINED"
    case focalToBilateralTc = "FOCAL_TO_BILATERAL_TC"
    case generalizedUndetermined = "GENERALIZED_UNDETERMINED"
    case generalizedTc = "GENERALIZED_TC"
    case genClonic = "GEN_CLONIC"
    case genTonic = "GEN_TONIC"
    case genMyoclonic = "GEN_MYOCLONIC"
    case genMyoclonicAtonic = "GEN_MYOCLONIC_ATONIC"
    case genAtonic = "GEN_ATONIC"
    case genNegativeMyoclonic = "GEN_NEGATIVE_MYOCLONIC"
    case genSpasms = "GEN_SPASMS"
    case absenceTypical = "ABSENCE_TYPICAL"
    case absenceAtypical = "ABSENCE_ATYPICAL"
    case absenceMyoclonic = "ABSENCE_MYOCLONIC"
    case eyelidMyoclonia = "EYELID_MYOCLONIA"
    case unknownUndetermined = "UNKNOWN_UNDETERMINED"
    case unknownPreserved = "UNKNOWN_PRESERVED"
    case unknownImpaired = "UNKNOWN_IMPAIRED"
    case unknownBilateralTc = "UNKNOWN_BILATERAL_TC"
    case unclassified = "UNCLASSIFIED"
    case unrecognized = "__UNRECOGNIZED__"

    public static let unknownFallback = SeizureIlaeType.unrecognized
    public static let wireVocabulary: StaticString = "seizure ILAE type"

    /// The class the type belongs to.
    public var ilaeClass: SeizureIlaeClass {
        switch self {
        case .focalPreserved, .focalImpaired, .focalUndetermined, .focalToBilateralTc: .focal
        case .generalizedUndetermined, .generalizedTc, .genClonic, .genTonic, .genMyoclonic, .genMyoclonicAtonic,
             .genAtonic, .genNegativeMyoclonic, .genSpasms, .absenceTypical, .absenceAtypical, .absenceMyoclonic,
             .eyelidMyoclonia: .generalized
        case .unknownUndetermined, .unknownPreserved, .unknownImpaired, .unknownBilateralTc: .unknown
        case .unclassified: .unclassified
        case .unrecognized: .unrecognized
        }
    }

    /// The parent-class entry ("not sure" at the second step).
    public var isParent: Bool {
        [.focalUndetermined, .generalizedUndetermined, .unknownUndetermined].contains(self)
    }

    /// Bilateral tonic-clonic: the convulsive types.
    public var isConvulsive: Bool {
        [.focalToBilateralTc, .generalizedTc, .unknownBilateralTc].contains(self)
    }

    /// The types of `ilaeClass`, the parent entry first.
    public static func types(in ilaeClass: SeizureIlaeClass) -> [SeizureIlaeType] {
        let members = allCases.filter { $0 != .unrecognized && $0.ilaeClass == ilaeClass }
        return members.filter(\.isParent) + members.filter { !$0.isParent }
    }

    public var label: String {
        switch self {
        case .focalPreserved: String(localized: "seizures.ilae.FOCAL_PRESERVED")
        case .focalImpaired: String(localized: "seizures.ilae.FOCAL_IMPAIRED")
        case .focalUndetermined: String(localized: "seizures.ilae.FOCAL_UNDETERMINED")
        case .focalToBilateralTc: String(localized: "seizures.ilae.FOCAL_TO_BILATERAL_TC")
        case .generalizedUndetermined: String(localized: "seizures.ilae.GENERALIZED_UNDETERMINED")
        case .generalizedTc: String(localized: "seizures.ilae.GENERALIZED_TC")
        case .genClonic: String(localized: "seizures.ilae.GEN_CLONIC")
        case .genTonic: String(localized: "seizures.ilae.GEN_TONIC")
        case .genMyoclonic: String(localized: "seizures.ilae.GEN_MYOCLONIC")
        case .genMyoclonicAtonic: String(localized: "seizures.ilae.GEN_MYOCLONIC_ATONIC")
        case .genAtonic: String(localized: "seizures.ilae.GEN_ATONIC")
        case .genNegativeMyoclonic: String(localized: "seizures.ilae.GEN_NEGATIVE_MYOCLONIC")
        case .genSpasms: String(localized: "seizures.ilae.GEN_SPASMS")
        case .absenceTypical: String(localized: "seizures.ilae.ABSENCE_TYPICAL")
        case .absenceAtypical: String(localized: "seizures.ilae.ABSENCE_ATYPICAL")
        case .absenceMyoclonic: String(localized: "seizures.ilae.ABSENCE_MYOCLONIC")
        case .eyelidMyoclonia: String(localized: "seizures.ilae.EYELID_MYOCLONIA")
        case .unknownUndetermined: String(localized: "seizures.ilae.UNKNOWN_UNDETERMINED")
        case .unknownPreserved: String(localized: "seizures.ilae.UNKNOWN_PRESERVED")
        case .unknownImpaired: String(localized: "seizures.ilae.UNKNOWN_IMPAIRED")
        case .unknownBilateralTc: String(localized: "seizures.ilae.UNKNOWN_BILATERAL_TC")
        case .unclassified: String(localized: "seizures.ilae.UNCLASSIFIED")
        case .unrecognized: String(localized: "seizures.untyped")
        }
    }
}
