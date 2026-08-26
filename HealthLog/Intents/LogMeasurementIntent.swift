import AppIntents
import Foundation

/// **v0.15 W-SIRI — the generic "log a measurement" Siri / Shortcuts intent.**
///
/// The shipped write intents are per-metric (`LogBloodPressureIntent`,
/// `LogBloodGlucoseIntent`, `LogMoodIntent`). Those stay — blood pressure
/// needs a systolic/diastolic pair, glucose carries a meal context, mood is
/// a five-level enum — but every *scalar* metric the user logs by hand
/// (weight, pulse, body temperature, SpO₂, respiratory rate, body fat …)
/// previously had no voice/Shortcut route. This one intent closes that gap:
/// pick a kind, say a value, and it routes through the **same**
/// `MeasurementsRepository.create` path the manual-entry sheet uses —
/// optimistic server POST with an idempotency key, Outbox fallback on a
/// network error, exactly-once replay on the next foreground. No parallel
/// write path, no new endpoint.
///
/// Blood pressure and mood are deliberately **absent** from the kind picker:
/// they have richer dedicated intents (a pair / an enum), so routing them
/// through a single-scalar intent would be a worse experience. Glucose stays
/// available here as a plain scalar (no meal context) for "log my blood sugar
/// 95" convenience; the dedicated `LogBloodGlucoseIntent` remains for the
/// context-carrying flow.
///
/// Runs without launching the app (`openAppWhenRun = false`) — dependencies
/// resolve from the Keychain + a recovered Outbox via ``IntentDependencies``.
/// Signed-out surfaces the friendly sign-in dialog rather than a doomed 401.
struct LogMeasurementIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a measurement"

    static let description = IntentDescription(
        "Record a health measurement (weight, pulse, temperature and more) in HealthLog."
    )

    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Measurement",
        description: "Which measurement to log."
    )
    var kind: MeasurableKindAppEnum

    @Parameter(
        title: "Value",
        description: "The measured value, in the kind's standard unit."
    )
    var value: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$value) \(\.$kind)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        // Reject a non-finite / out-of-range scalar before persisting a
        // nonsensical row. The per-kind range mirrors the in-app sheet's
        // sanity bounds; outside it we surface a dialog rather than write.
        guard kind.isPlausible(value) else {
            return .result(dialog: IntentDialog(IntentCopy.measurementOutOfRange))
        }

        let measurement = Measurement(
            id: UUID().uuidString,
            kind: kind.domainKind,
            recordedAt: Date(),
            value: .scalar(value),
            source: .manual
        )

        do {
            _ = try await deps.measurementsRepo.create(measurement)
            let shaped = value.formatted(.number.precision(.fractionLength(0 ... 1)))
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "intents.logMeasurement.confirmed",
                        defaultValue: "Logged \(shaped) \(kind.spokenUnit) \(kind.spokenName).",
                        comment: "AppIntents — generic measurement logged confirmation; %1$@ value, %2$@ unit, %3$@ kind"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Optimistic-write contract: the value is on the Outbox and will
            // sync on the next app foreground (incl. a transient-refresh 401
            // the repo durably enqueued). Tell the user it's saved, not lost.
            return .result(dialog: IntentCopy.queuedOffline)
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}

/// **v0.15 W-SIRI** — the scalar metric kinds the generic log intent offers
/// to Siri / Shortcuts. A curated subset of ``MetricKind``: the metrics a
/// user realistically logs by hand and that carry a single scalar value.
///
/// Excludes blood pressure (pair → ``LogBloodPressureIntent``) and the
/// derived / passively-synced kinds (steps, HRV, VO₂ max, walking metrics …)
/// that come from HealthKit, never a manual voice log. Each case maps onto a
/// domain ``MetricKind`` so the server stores the identical type the in-app
/// sheet writes — no new wire type.
enum MeasurableKindAppEnum: String, AppEnum, CaseIterable {
    case weight
    case pulse
    case glucose
    case bodyTemperature
    case spo2
    case respiratoryRate
    case bodyFat

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Measurement"
    )

    static let caseDisplayRepresentations: [MeasurableKindAppEnum: DisplayRepresentation] = [
        .weight: DisplayRepresentation(title: "Weight"),
        .pulse: DisplayRepresentation(title: "Pulse"),
        .glucose: DisplayRepresentation(title: "Blood glucose"),
        .bodyTemperature: DisplayRepresentation(title: "Body temperature"),
        .spo2: DisplayRepresentation(title: "Blood oxygen"),
        .respiratoryRate: DisplayRepresentation(title: "Respiratory rate"),
        .bodyFat: DisplayRepresentation(title: "Body fat")
    ]

    /// Map onto the domain enum the measurement model carries so the server
    /// row keys on the same `MetricKind` the in-app sheet writes.
    var domainKind: MetricKind {
        switch self {
        case .weight: .weight
        case .pulse: .pulse
        case .glucose: .glucose
        case .bodyTemperature: .bodyTemperature
        case .spo2: .spo2
        case .respiratoryRate: .respiratoryRate
        case .bodyFat: .bodyFat
        }
    }

    /// Localized lower-case kind name woven into the spoken confirmation
    /// ("Logged 72 kg weight."). Pulled from the catalogue display titles so
    /// the picker and the read-back agree.
    var spokenName: LocalizedStringResource {
        switch self {
        case .weight: LocalizedStringResource("intents.kind.weight", defaultValue: "weight", comment: "AppIntents — spoken metric kind")
        case .pulse: LocalizedStringResource("intents.kind.pulse", defaultValue: "pulse", comment: "AppIntents — spoken metric kind")
        case .glucose: LocalizedStringResource(
                "intents.kind.glucose",
                defaultValue: "blood glucose",
                comment: "AppIntents — spoken metric kind"
            )
        case .bodyTemperature: LocalizedStringResource(
                "intents.kind.bodyTemperature",
                defaultValue: "body temperature",
                comment: "AppIntents — spoken metric kind"
            )
        case .spo2: LocalizedStringResource("intents.kind.spo2", defaultValue: "blood oxygen", comment: "AppIntents — spoken metric kind")
        case .respiratoryRate: LocalizedStringResource(
                "intents.kind.respiratoryRate",
                defaultValue: "respiratory rate",
                comment: "AppIntents — spoken metric kind"
            )
        case .bodyFat: LocalizedStringResource("intents.kind.bodyFat", defaultValue: "body fat", comment: "AppIntents — spoken metric kind")
        }
    }

    /// The unit spoken back in the confirmation. Server-canonical base unit
    /// per kind (kg / bpm / mg/dL / °C / % / br/min) — the intent writes the
    /// base unit, matching the repository's wire contract.
    var spokenUnit: LocalizedStringResource {
        switch self {
        case .weight: LocalizedStringResource("intents.unit.kg", defaultValue: "kilograms", comment: "AppIntents — spoken unit")
        case .pulse, .respiratoryRate: LocalizedStringResource(
                "intents.unit.perMinute",
                defaultValue: "per minute",
                comment: "AppIntents — spoken unit"
            )
        case .glucose: LocalizedStringResource(
                "intents.unit.mgdl",
                defaultValue: "milligrams per deciliter",
                comment: "AppIntents — spoken unit"
            )
        case .bodyTemperature: LocalizedStringResource(
                "intents.unit.celsius",
                defaultValue: "degrees Celsius",
                comment: "AppIntents — spoken unit"
            )
        case .spo2, .bodyFat: LocalizedStringResource("intents.unit.percent", defaultValue: "percent", comment: "AppIntents — spoken unit")
        }
    }

    /// Per-kind plausibility bounds (inclusive). Pure + testable — rejects a
    /// transposed / fat-fingered value before it reaches the server. Mirrors
    /// the sanity ranges the in-app entry sheet enforces.
    func isPlausible(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let range: ClosedRange<Double> = switch self {
        case .weight: 1 ... 700 // kg
        case .pulse: 20 ... 300 // bpm
        case .glucose: 10 ... 1000 // mg/dL
        case .bodyTemperature: 25 ... 45 // °C
        case .spo2: 50 ... 100 // %
        case .respiratoryRate: 3 ... 80 // br/min
        case .bodyFat: 1 ... 75 // %
        }
        return range.contains(value)
    }
}
