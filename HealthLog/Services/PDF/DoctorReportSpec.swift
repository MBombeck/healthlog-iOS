import Foundation

/// **Local Doctor Report — Spec (T-7).**
///
/// Sendable plan struct that captures every byte of content destined for
/// the PDF. The renderer-actor walks this struct top-to-bottom and emits
/// one section per non-nil field, in the order declared below. The plan
/// is **derived once on the @MainActor** from the live stores (so the
/// renderer can stay isolation-free) and then handed to the actor for
/// drawing.
///
/// **Boundary:** this is a pure data container — no fetching, no rendering.
/// Building blocks live next to the data fields so the unit-test surface
/// is "given a snapshot, the spec contains exactly these section bodies".
public struct DoctorReportSpec: Sendable, Equatable {
    public let cover: Cover
    public let vitals: VitalsSummary?
    public let charts: ChartsBlock?
    public let medications: MedicationsBlock?
    public let adherence: AdherenceBlock?
    public let mood: MoodBlock?
    /// v1.18.1 — lab results destined for a FHIR `Observation` per row
    /// (category `laboratory`). `nil` when the `labs` module is off or there
    /// are no results. PDF rendering of labs is out of scope for now — the
    /// block feeds the FHIR bundle only.
    public let labs: LabsBlock?
    /// v1.18.1 — illness/condition episodes destined for a FHIR `Condition`
    /// per episode (+ supporting day-log `Observation`s). `nil` when the
    /// `illness` module is off or there are no episodes.
    public let illnesses: IllnessBlock?
    public let footer: Footer

    public init(
        cover: Cover,
        vitals: VitalsSummary?,
        charts: ChartsBlock?,
        medications: MedicationsBlock?,
        adherence: AdherenceBlock?,
        mood: MoodBlock?,
        labs: LabsBlock? = nil,
        illnesses: IllnessBlock? = nil,
        footer: Footer
    ) {
        self.cover = cover
        self.vitals = vitals
        self.charts = charts
        self.medications = medications
        self.adherence = adherence
        self.mood = mood
        self.labs = labs
        self.illnesses = illnesses
        self.footer = footer
    }

    // MARK: - Cover

    public struct Cover: Sendable, Equatable {
        public let patientName: String
        /// v0.10.0 — extended patient-identity fields. A doctor report needs
        /// the full legal name + insurer + KVNR; each is omitted from the
        /// cover (and the FHIR Patient) when `nil`/empty. `insuranceNumber`
        /// is sensitive PII — it lives only on this in-memory spec and the
        /// drawn PDF bytes, and is **never** logged.
        public let fullName: String?
        public let insurerName: String?
        public let insuranceNumber: String?
        /// v0.11.0 — insurer IKNR (9-digit Institutionskennzeichen). Feeds the
        /// FHIR `Coverage` payor → contained `Organization.identifier`
        /// (`http://fhir.de/sid/arge-ik/iknr`). Identifying PII — in-memory
        /// on the spec only, never logged.
        public let insurerIkNumber: String?
        public let periodStart: Date
        public let periodEnd: Date
        public let generatedAt: Date
        public let appVersion: String
        public let locale: ReportLocale

        public init(
            patientName: String,
            fullName: String? = nil,
            insurerName: String? = nil,
            insuranceNumber: String? = nil,
            insurerIkNumber: String? = nil,
            periodStart: Date,
            periodEnd: Date,
            generatedAt: Date,
            appVersion: String,
            locale: ReportLocale
        ) {
            self.patientName = patientName
            self.fullName = fullName
            self.insurerName = insurerName
            self.insuranceNumber = insuranceNumber
            self.insurerIkNumber = insurerIkNumber
            self.periodStart = periodStart
            self.periodEnd = periodEnd
            self.generatedAt = generatedAt
            self.appVersion = appVersion
            self.locale = locale
        }
    }

    // MARK: - Vitals summary

    public struct VitalsSummary: Sendable, Equatable {
        public let rows: [Row]

        public init(rows: [Row]) {
            self.rows = rows
        }

        public struct Row: Sendable, Equatable, Identifiable {
            public let kind: MetricKind
            public let mean: Double
            public let median: Double
            public let min: Double
            public let max: Double
            public let count: Int
            /// Secondary mean for blood-pressure (diastolic). `nil` for every
            /// other metric. Mirrors `MeasurementValue.bloodPressure` shape.
            public let secondaryMean: Double?

            public var id: String {
                kind.rawValue
            }

            public init(
                kind: MetricKind,
                mean: Double,
                median: Double,
                min: Double,
                max: Double,
                count: Int,
                secondaryMean: Double? = nil
            ) {
                self.kind = kind
                self.mean = mean
                self.median = median
                self.min = min
                self.max = max
                self.count = count
                self.secondaryMean = secondaryMean
            }
        }
    }

    // MARK: - Charts

    public struct ChartsBlock: Sendable, Equatable {
        public let series: [Series]

        public init(series: [Series]) {
            self.series = series
        }

        public struct Series: Sendable, Equatable, Identifiable {
            public let kind: MetricKind
            public let points: [Point]

            public var id: String {
                kind.rawValue
            }

            public init(kind: MetricKind, points: [Point]) {
                self.kind = kind
                self.points = points
            }
        }

        public struct Point: Sendable, Equatable {
            public let at: Date
            public let value: Double
            /// Diastolic value for blood-pressure series. `nil` elsewhere.
            public let secondary: Double?

            public init(at: Date, value: Double, secondary: Double? = nil) {
                self.at = at
                self.value = value
                self.secondary = secondary
            }
        }
    }

    // MARK: - Medications

    public struct MedicationsBlock: Sendable, Equatable {
        public let active: [Row]
        public let archived: [Row]

        public init(active: [Row], archived: [Row]) {
            self.active = active
            self.archived = archived
        }

        public struct Row: Sendable, Equatable, Identifiable {
            public let id: String
            public let name: String
            public let dose: String
            public let treatmentClass: String?
            public let schedule: String

            public init(id: String, name: String, dose: String, treatmentClass: String?, schedule: String) {
                self.id = id
                self.name = name
                self.dose = dose
                self.treatmentClass = treatmentClass
                self.schedule = schedule
            }
        }
    }

    // MARK: - Adherence

    public struct AdherenceBlock: Sendable, Equatable {
        public let perMedication: [Row]
        public let overall: Double

        public init(perMedication: [Row], overall: Double) {
            self.perMedication = perMedication
            self.overall = overall
        }

        public struct Row: Sendable, Equatable, Identifiable {
            public let medicationId: String
            public let medicationName: String
            public let scheduled: Int
            public let taken: Int

            public var id: String {
                medicationId
            }

            public var rate: Double {
                scheduled == 0 ? 1 : Double(taken) / Double(scheduled)
            }

            public init(medicationId: String, medicationName: String, scheduled: Int, taken: Int) {
                self.medicationId = medicationId
                self.medicationName = medicationName
                self.scheduled = scheduled
                self.taken = taken
            }
        }
    }

    // MARK: - Mood

    public struct MoodBlock: Sendable, Equatable {
        public let sparkline: [Point]
        public let dominantTags: [TagCount]
        public let averageScore: Double
        public let count: Int

        public init(sparkline: [Point], dominantTags: [TagCount], averageScore: Double, count: Int) {
            self.sparkline = sparkline
            self.dominantTags = dominantTags
            self.averageScore = averageScore
            self.count = count
        }

        public struct Point: Sendable, Equatable {
            public let at: Date
            public let score: Int

            public init(at: Date, score: Int) {
                self.at = at
                self.score = score
            }
        }

        public struct TagCount: Sendable, Equatable, Identifiable {
            public let tag: String
            public let count: Int

            public var id: String {
                tag
            }

            public init(tag: String, count: Int) {
                self.tag = tag
                self.count = count
            }
        }
    }

    // MARK: - Labs (v1.18.1)

    /// Lab results for the FHIR export. Each row maps to one `Observation`
    /// (category `laboratory`). The DTO is already `Sendable`+`Equatable`, so
    /// the block carries it verbatim — the FHIR assembler reads `value`,
    /// `unit`, `analyte`, `biomarkerId`/`isLinked`, `referenceLow`/`High`,
    /// `rangeStatus`, and `takenAt` directly.
    public struct LabsBlock: Sendable, Equatable {
        public let results: [LabResultDTO]

        public init(results: [LabResultDTO]) {
            self.results = results
        }
    }

    // MARK: - Illness / Conditions (v1.18.1)

    /// Illness/condition episodes for the FHIR export. Each episode maps to one
    /// `Condition`; the (optional) day-logs map to supporting `Observation`s
    /// linked back to that Condition. Day-logs are keyed by `episodeId` so the
    /// assembler can attach them to the right Condition without recomputing.
    public struct IllnessBlock: Sendable, Equatable {
        public let episodes: [IllnessEpisodeDTO]
        /// Day-logs grouped by `episodeId`. Empty when the export carries
        /// episodes only (no per-day detail fetched).
        public let dayLogsByEpisode: [String: [IllnessDayLogDTO]]

        public init(
            episodes: [IllnessEpisodeDTO],
            dayLogsByEpisode: [String: [IllnessDayLogDTO]] = [:]
        ) {
            self.episodes = episodes
            self.dayLogsByEpisode = dayLogsByEpisode
        }
    }

    // MARK: - Footer

    public struct Footer: Sendable, Equatable {
        /// MDR + Class-IIa boundary — verbatim string baked at spec time so
        /// the renderer cannot accidentally rewrite it. Operator copy-deck
        /// is locked: see `DoctorReportLocalSpecTests.footerDisclaimer*`.
        public let disclaimer: String

        public init(disclaimer: String) {
            self.disclaimer = disclaimer
        }
    }
}

// MARK: - Locale gate

/// Report locale — DE primary, EN secondary. Forced at spec-build time so
/// the renderer's date-formatter + section-titles agree on one language,
/// even when the system locale differs (operator may share the PDF with
/// an English-speaking specialist).
public enum ReportLocale: String, Sendable, Equatable, CaseIterable {
    case de
    case en

    public var bcp47: String {
        rawValue
    }

    public var foundationIdentifier: String {
        switch self {
        case .de: "de_DE"
        case .en: "en_US"
        }
    }
}

// MARK: - Selection (user-facing toggles)

/// The seven sections the user can toggle from the export-screen. Cover
/// + Footer always render. Each toggle independently maps to the
/// matching `DoctorReportSpec.*` field staying non-nil after fetching.
public struct DoctorReportSectionSelection: Sendable, Equatable {
    public var vitals: Bool
    public var charts: Bool
    public var medications: Bool
    public var adherence: Bool
    public var mood: Bool

    public init(
        vitals: Bool = true,
        charts: Bool = true,
        medications: Bool = true,
        adherence: Bool = true,
        mood: Bool = true
    ) {
        self.vitals = vitals
        self.charts = charts
        self.medications = medications
        self.adherence = adherence
        self.mood = mood
    }

    public static let all = Self()
    public static let none = Self(
        vitals: false,
        charts: false,
        medications: false,
        adherence: false,
        mood: false
    )
}

// MARK: - Locked disclaimer strings (MDR / Class-IIa boundary)

/// Verbatim copy locked by the operator (Phase T-7 dispatch). Any change
/// here is a compliance-affecting copy edit — must go through the operator + the
/// MDR-disclaimer test (`DoctorReportLocalSpecTests.footerDisclaimer*`).
public enum DoctorReportDisclaimer {
    public static let de = "Lokaler Export · kein Server beteiligt · auf-Geraet erzeugt · kein medizinisches Dokument"
    public static let en = "Local export · no server involved · generated on-device · not a medical document"

    public static func text(for locale: ReportLocale) -> String {
        switch locale {
        case .de: de
        case .en: en
        }
    }
}
