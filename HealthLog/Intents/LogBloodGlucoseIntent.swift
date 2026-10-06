import AppIntents
import Foundation

/// **v0.7.1 W-APPINTENTS** — "Log blood glucose" Siri / Shortcuts intent.
///
/// Records a single glucose reading through the **same**
/// `MeasurementsRepository.create` path the manual-entry sheet uses:
/// optimistic server POST with an idempotency key, falling back to the
/// Outbox on a network error so the value replays exactly-once on the
/// next app foreground. No parallel write path.
///
/// Runs without launching the full app — dependencies resolve from the
/// Keychain + a recovered Outbox via ``IntentDependencies``. When the
/// user is not signed in we surface a friendly dialog rather than firing
/// a doomed 401.
///
/// **#115 B5 — the spoken value is in the ACCOUNT's unit.** It was fixed
/// mg/dL, so an mmol/L account said "5.3" and had it refused (or, from 10 up,
/// stored as mg/dL). The value is now read in the account's glucose unit
/// (``IntentDependencies/accountGlucoseUnit(shared:appDefaults:)``), converted
/// to canonical mg/dL for the write — the server stores mg/dL whatever the
/// account shows — and read back in the unit it was said in.
struct LogBloodGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log blood glucose"

    static let description = IntentDescription(
        "Record a blood glucose reading in HealthLog."
    )

    /// We want the confirmation + result dialog to read back to the user
    /// in Siri, so the intent does not open the app.
    static let openAppWhenRun: Bool = false

    /// Bounds wide enough for both units (0.5 mmol/L … 1000 mg/dL); the real
    /// plausibility check runs on the canonical value in ``perform()``.
    @Parameter(
        title: "Blood glucose",
        description: "Your blood glucose reading, in the unit your HealthLog account uses (mg/dL or mmol/L).",
        inclusiveRange: (0.5, 1000)
    )
    var value: Double

    @Parameter(
        title: "Context",
        description: "When the reading was taken.",
        default: .unspecified
    )
    var context: GlucoseContextAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$value) blood glucose \(\.$context)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        let unit = deps.glucoseUnit()
        guard let canonical = Self.canonicalValue(value, unit: unit) else {
            return .result(dialog: IntentDialog(IntentCopy.measurementOutOfRange))
        }

        let measurement = Measurement(
            id: UUID().uuidString,
            kind: .glucose,
            recordedAt: Date(),
            value: .scalar(canonical),
            source: .manual,
            glucoseContext: context.domainValue
        )

        do {
            _ = try await deps.measurementsRepo.create(measurement)
            let shaped = value.formatted(.number.precision(.fractionLength(0 ... 1)))
            let suffix = unit.unitSuffix
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "Logged \(shaped) \(suffix) blood glucose.",
                        comment: "AppIntents — blood glucose logged confirmation; %1$@ value, %2$@ unit (mg/dL or mmol/L)"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Optimistic-write contract: the value is now in the Outbox
            // and will sync on the next app foreground (incl. a transient-
            // refresh 401 the repo durably enqueued). Tell the user it
            // is saved (not lost) so an offline log still feels reliable.
            return .result(dialog: IntentCopy.queued(after: error))
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}

extension LogBloodGlucoseIntent {
    /// #115 B5 — a value spoken in `unit`, in canonical mg/dL; `nil` when it is
    /// not a plausible reading (10…1000 mg/dL, the band the parameter used to
    /// enforce, now checked after the conversion so it holds in either unit).
    static func canonicalValue(_ value: Double, unit: GlucoseUnit) -> Double? {
        guard value.isFinite else { return nil }
        let canonical = unit.canonicalMgdL(fromDisplayed: value)
        return (10 ... 1000).contains(canonical) ? canonical : nil
    }
}

/// Glucose-context picker surfaced to Siri / Shortcuts. Maps onto the
/// domain `GlucoseContext` so the server stores the same discriminator
/// the in-app sheet writes.
enum GlucoseContextAppEnum: String, AppEnum {
    case unspecified
    case fasting
    case beforeMeal
    case afterMeal
    case bedtime

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Glucose context"
    )

    static let caseDisplayRepresentations: [GlucoseContextAppEnum: DisplayRepresentation] = [
        .unspecified: DisplayRepresentation(title: "Unspecified"),
        .fasting: DisplayRepresentation(title: "Fasting"),
        .beforeMeal: DisplayRepresentation(title: "Before meal"),
        .afterMeal: DisplayRepresentation(title: "After meal"),
        .bedtime: DisplayRepresentation(title: "Bedtime")
    ]

    /// Map onto the domain enum the measurement model carries. Returns
    /// `nil` for `.unspecified` so the server row simply has no context.
    var domainValue: GlucoseContext? {
        switch self {
        case .unspecified: nil
        case .fasting: .fasting
        case .beforeMeal: .beforeMeal
        case .afterMeal: .afterMeal
        case .bedtime: .bedtime
        }
    }
}
