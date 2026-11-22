import Foundation

/// What the configured server serves of the Apple Health ingest v2
/// (`CONTRACT-apple-health-v2.md`): the `features` flags of `GET /api/auth/me`.
///
/// Fail closed. A flag counts when the server reported it; the two whose
/// routes shipped with server 1.48.0 also count from that version on, so the
/// live server works before it publishes the flag. The symptom batch has no
/// fallback: it exists only where the server says so.
enum AppleHealthIngestCapability {
    /// The release that shipped the routes behind a flag, where one did.
    static func shippedIn(_ feature: KnownServerVersion.Feature) -> String? {
        switch feature {
        case .appleHealthDeletes, .nutrientMacros: "1.48.0"
        case .appleHealthSymptoms, .cumulativeHourBuckets, .syncTriggerBackfill: nil
        }
    }

    static func isAvailable(_ feature: KnownServerVersion.Feature, defaults: UserDefaults = .standard) -> Bool {
        let raw = defaults.stringArray(forKey: KnownServerVersion.featuresDefaultsKey) ?? []
        if raw.contains(feature.rawValue), KnownServerVersion.isAtLeast("1.43.0", defaults: defaults) {
            return true
        }
        guard let shipped = shippedIn(feature) else { return false }
        return KnownServerVersion.isAtLeast(shipped, defaults: defaults)
    }
}

/// The Apple Health types this build adds after 1.6, by registry (run-time)
/// identifier, and how each one reaches the server.
enum AppleHealthIngestTypes {
    static let hypertensionEvent = "HKCategoryTypeIdentifierHypertensionEvent"
    static let lowCardioFitnessEvent = "HKCategoryTypeIdentifierLowCardioFitnessEvent"
    static let menopausalState = "HKCategoryTypeIdentifierMenopausalState"
    static let bleedingAfterMenopause = "HKCategoryTypeIdentifierBleedingAfterMenopause"
    static let phq9 = "HKScoredAssessmentTypeIdentifierPHQ9"
    static let gad7 = "HKScoredAssessmentTypeIdentifierGAD7"

    /// The first server release that maps a measurement-batch type, where one
    /// already does. Without a published `acceptedTypes` list this decides.
    static let minimumServerVersionByIdentifier: [String: String] = [
        hypertensionEvent: "1.48.0",
        phq9: "1.48.0",
        gad7: "1.48.0"
    ].merging(AppleHealthIngestQuantityTypes.minimumServerVersionByIdentifier) { current, _ in current }

    /// Measurement-batch types no released server maps yet: collected only
    /// once the server lists them in `acceptedTypes`, never by version.
    static let publishedOnlyIdentifiers: Set<String> = Set([
        lowCardioFitnessEvent, menopausalState, bleedingAfterMenopause
    ]).union(AppleHealthIngestQuantityTypes.publishedOnlyIdentifiers)

    /// The category events that ride the heart-event path, behind the seven
    /// older ones, in sweep order.
    static let eventIdentifiers: [String] = [
        hypertensionEvent, lowCardioFitnessEvent, menopausalState, bleedingAfterMenopause
    ]

    /// PHQ-9 and GAD-7 (`HKScoredAssessment`).
    static let assessmentIdentifiers: [String] = [phq9, gad7]

    /// The HealthKit release each type first exists in, where it is newer
    /// than the iOS 18 deployment target.
    static let minimumOSMajorMinor: [String: (Int, Int)] = [
        hypertensionEvent: (26, 2),
        menopausalState: (27, 0),
        bleedingAfterMenopause: (27, 0)
    ]

    /// Every type this build adds, in the order the card and the sweep use.
    /// The quantity types and the basal body temperature joined later in 1.7.
    static var allIdentifiers: [String] {
        eventIdentifiers + assessmentIdentifiers + AppleHealthSymptomCatalog.identifiers
            + AppleHealthIngestQuantityTypes.allIdentifiers + [CycleBasalTemperature.identifier]
    }

    /// Whether the configured server takes `identifier` now. Symptoms follow
    /// their feature flag; the basal body temperature rides the cycle
    /// day-log every server takes, so it waits only for cycle tracking;
    /// everything else follows the measurement-batch gate.
    static func serverAccepts(_ identifier: String, defaults: UserDefaults = .standard) -> Bool {
        if AppleHealthSymptomCatalog.code(for: identifier) != nil {
            return AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: defaults)
        }
        if identifier == CycleBasalTemperature.identifier {
            return CycleBasalTemperature.isCycleImportActive(defaults: defaults)
        }
        return HealthKitServerTypeGate.serverAccepts(identifier, defaults: defaults)
    }

    /// Whether this system's HealthKit has the type at all.
    static func isAvailableOnThisSystem(
        _ identifier: String,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        guard let minimum = minimumOSMajorMinor[identifier] else { return true }
        return (version.majorVersion, version.minorVersion) >= minimum
    }
}

/// The HealthKit symptoms the symptom diary takes (contract §2.1): all 39.
/// The eleven the cycle day-log also carries go both ways, here always and to
/// the cycle route while cycle tracking is on; each way keeps its own cursor.
enum AppleHealthSymptomCatalog {
    private static let prefix = "HKCategoryTypeIdentifier"

    /// HealthKit suffix to server code, in table order.
    static let codesBySuffix: [(suffix: String, code: String)] = [
        ("AbdominalCramps", "ABDOMINAL_CRAMPS"),
        ("Acne", "ACNE"),
        ("AppetiteChanges", "APPETITE_CHANGES"),
        ("BladderIncontinence", "BLADDER_INCONTINENCE"),
        ("Bloating", "BLOATING"),
        ("BreastPain", "BREAST_PAIN"),
        ("ChestTightnessOrPain", "CHEST_TIGHTNESS_OR_PAIN"),
        ("Chills", "CHILLS"),
        ("Constipation", "CONSTIPATION"),
        ("Coughing", "COUGHING"),
        ("Diarrhea", "DIARRHEA"),
        ("Dizziness", "DIZZINESS"),
        ("DrySkin", "DRY_SKIN"),
        ("Fainting", "FAINTING"),
        ("Fatigue", "FATIGUE"),
        ("Fever", "FEVER"),
        ("GeneralizedBodyAche", "GENERALIZED_BODY_ACHE"),
        ("HairLoss", "HAIR_LOSS"),
        ("Headache", "HEADACHE"),
        ("Heartburn", "HEARTBURN"),
        ("HotFlashes", "HOT_FLASHES"),
        ("LossOfSmell", "LOSS_OF_SMELL"),
        ("LossOfTaste", "LOSS_OF_TASTE"),
        ("LowerBackPain", "LOWER_BACK_PAIN"),
        ("MemoryLapse", "MEMORY_LAPSE"),
        ("MoodChanges", "MOOD_CHANGES"),
        ("Nausea", "NAUSEA"),
        ("NightSweats", "NIGHT_SWEATS"),
        ("PelvicPain", "PELVIC_PAIN"),
        ("RapidPoundingOrFlutteringHeartbeat", "RAPID_POUNDING_OR_FLUTTERING_HEARTBEAT"),
        ("RunnyNose", "RUNNY_NOSE"),
        ("ShortnessOfBreath", "SHORTNESS_OF_BREATH"),
        ("SinusCongestion", "SINUS_CONGESTION"),
        ("SkippedHeartbeat", "SKIPPED_HEARTBEAT"),
        ("SleepChanges", "SLEEP_CHANGES"),
        ("SoreThroat", "SORE_THROAT"),
        ("VaginalDryness", "VAGINAL_DRYNESS"),
        ("Vomiting", "VOMITING"),
        ("Wheezing", "WHEEZING")
    ]

    static let identifiers: [String] = codesBySuffix.map { prefix + $0.suffix }

    private static let codeByIdentifier: [String: String] = Dictionary(
        uniqueKeysWithValues: codesBySuffix.map { (prefix + $0.suffix, $0.code) }
    )

    static func code(for identifier: String) -> String? {
        codeByIdentifier[identifier]
    }

    /// The three symptoms HealthKit records with a presence or appetite value
    /// instead of a severity.
    static let presenceValued: Set<String> = [
        prefix + "AppetiteChanges", prefix + "MoodChanges", prefix + "SleepChanges"
    ]

    /// The diary intensity of one sample. Severity types go through the scale
    /// below; the presence-valued three: present (or any appetite change) is 5,
    /// "not present" (`0`, appetite `noChange` = 1) is not sent.
    static func intensity(forValue rawValue: Int, identifier: String) -> Int? {
        guard presenceValued.contains(identifier) else { return intensity(forSeverity: rawValue) }
        if identifier == prefix + "AppetiteChanges" {
            // HKCategoryValueAppetiteChanges: unspecified 0, noChange 1, decreased 2, increased 3.
            return rawValue == 1 ? nil : 5
        }
        // HKCategoryValuePresence: present 0, notPresent 1.
        return rawValue == 0 ? 5 : nil
    }

    /// `HKCategoryValueSeverity` to the diary's 0-10 scale. `nil` for
    /// "not present" and anything unknown: such a sample is not sent.
    static func intensity(forSeverity rawValue: Int) -> Int? {
        switch rawValue {
        case 0: 5 // unspecified
        case 2: 3 // mild
        case 3: 6 // moderate
        case 4: 9 // severe
        default: nil // 1 = not present
        }
    }
}

/// One line of the Sync Diagnostics card for the ingest-v2 groups.
struct AppleHealthIngestStatusRow: Equatable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case hypertension, lowCardioFitness, menopause, assessments, symptoms, macros, deletes
        case insulinAndBreathing, effort, training, basalTemperature, readingTimeZone
    }

    enum State: Equatable, Sendable {
        /// The server takes it; the app reads and sends it.
        case active
        /// The server does not take it yet; nothing is read or sent.
        case waitingForServer
        /// This system's HealthKit does not have the type.
        case notOnThisSystem
        /// The area it belongs to is switched off here (cycle tracking for
        /// the basal body temperature).
        case areaOff
    }

    let group: Group
    let state: State

    /// The groups as this system and the configured server see them now.
    static func current(
        defaults: UserDefaults = .standard,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [AppleHealthIngestStatusRow] {
        Group.allCases.map { group in
            AppleHealthIngestStatusRow(group: group, state: state(of: group, defaults: defaults, version: version))
        }
    }

    private static func state(of group: Group, defaults: UserDefaults, version: OperatingSystemVersion) -> State {
        switch group {
        case .macros:
            AppleHealthIngestCapability.isAvailable(.nutrientMacros, defaults: defaults) ? .active : .waitingForServer
        case .deletes:
            AppleHealthIngestCapability.isAvailable(.appleHealthDeletes, defaults: defaults) ? .active : .waitingForServer
        case .symptoms:
            AppleHealthIngestCapability.isAvailable(.appleHealthSymptoms, defaults: defaults) ? .active : .waitingForServer
        case .hypertension:
            typeState([AppleHealthIngestTypes.hypertensionEvent], defaults: defaults, version: version)
        case .lowCardioFitness:
            typeState([AppleHealthIngestTypes.lowCardioFitnessEvent], defaults: defaults, version: version)
        case .menopause:
            typeState(
                [AppleHealthIngestTypes.menopausalState, AppleHealthIngestTypes.bleedingAfterMenopause],
                defaults: defaults,
                version: version
            )
        case .assessments:
            typeState(AppleHealthIngestTypes.assessmentIdentifiers, defaults: defaults, version: version)
        case .insulinAndBreathing:
            typeState(AppleHealthIngestQuantityTypes.respiratoryIdentifiers, defaults: defaults, version: version)
        case .effort:
            typeState(AppleHealthIngestQuantityTypes.effortIdentifiers, defaults: defaults, version: version)
        case .training:
            typeState(AppleHealthIngestQuantityTypes.trainingIdentifiers, defaults: defaults, version: version)
        case .basalTemperature:
            // Waits for cycle tracking, not for the server.
            CycleBasalTemperature.isCycleImportActive(defaults: defaults) ? .active : .areaOff
        case .readingTimeZone:
            HealthKitReadingTimeZone.isSent(defaults: defaults) ? .active : .waitingForServer
        }
    }

    private static func typeState(_ identifiers: [String], defaults: UserDefaults, version: OperatingSystemVersion) -> State {
        let onSystem = identifiers.filter { AppleHealthIngestTypes.isAvailableOnThisSystem($0, version: version) }
        guard !onSystem.isEmpty else { return .notOnThisSystem }
        return onSystem.contains { AppleHealthIngestTypes.serverAccepts($0, defaults: defaults) } ? .active : .waitingForServer
    }
}

enum AppleHealthDeleteRefusal {
    /// 403 `module.disabled` / `illness.disabled`.
    static func isModuleOff(_ error: Error) -> Bool {
        if case .moduleDisabled = error as? HLError { return true }
        return false
    }

    /// A delete the server read and refused (a 4xx other than 401, 408 and
    /// 429): the same body would earn the same answer, so it is not retried.
    static func isFinal(_ error: Error) -> Bool {
        guard let error = error as? HLError else { return false }
        if case .decoding = error { return false }
        // A module that is off pauses the route; the cursor holds.
        if isModuleOff(error) { return false }
        return error != .serverNotConfigured && !error.shouldPersistToOutbox
    }
}

/// Deletions read while the server has no delete route yet. The anchor may
/// move past them only because they wait here, per account and route, until
/// the route opens; then they go out ahead of the new ones.
enum AppleHealthPendingDeletions {
    /// A bound per account and route; past it the oldest wait no longer.
    static let maxPending = 5000

    static func key(_ domain: AppleHealthDeleteDomain, ownerID: String) -> String {
        "hl.ingest.pendingDeletes." + domain.rawValue + "." + ownerID
    }

    static func pending(_ domain: AppleHealthDeleteDomain, ownerID: String, defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: key(domain, ownerID: ownerID)) ?? []
    }

    static func keep(_ ids: [String], _ domain: AppleHealthDeleteDomain, ownerID: String, defaults: UserDefaults) {
        guard !ids.isEmpty else { return }
        var seen = Set<String>()
        let merged = (pending(domain, ownerID: ownerID, defaults: defaults) + ids).filter { seen.insert($0).inserted }
        defaults.set(Array(merged.suffix(maxPending)), forKey: key(domain, ownerID: ownerID))
    }

    static func clear(_ domain: AppleHealthDeleteDomain, ownerID: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: key(domain, ownerID: ownerID))
    }

    /// What to send now: nothing while the route is closed (the ids are kept),
    /// otherwise everything kept before plus `newIDs`. Clear the list with
    /// ``clear(_:ownerID:defaults:)`` once the send landed.
    static func toSend(
        _ newIDs: [String],
        _ domain: AppleHealthDeleteDomain,
        ownerID: String,
        routeOpen: Bool,
        defaults: UserDefaults
    ) -> [String] {
        guard routeOpen else {
            keep(newIDs, domain, ownerID: ownerID, defaults: defaults)
            return []
        }
        var seen = Set<String>()
        return (pending(domain, ownerID: ownerID, defaults: defaults) + newIDs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One page's deletions for `domain`: kept while the route is closed,
    /// otherwise sent together with everything kept before. Throws when the
    /// send fails; what was kept stays kept, and the caller holds its anchor.
    static func deliver(
        _ newIDs: [String],
        _ domain: AppleHealthDeleteDomain,
        ownerID: String,
        routeOpen: Bool,
        defaults: UserDefaults,
        send: @Sendable ([String]) async throws -> Void
    ) async throws {
        let all = toSend(newIDs, domain, ownerID: ownerID, routeOpen: routeOpen, defaults: defaults)
        guard !all.isEmpty else { return }
        try await send(all)
        clear(domain, ownerID: ownerID, defaults: defaults)
    }
}
