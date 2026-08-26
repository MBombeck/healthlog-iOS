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
struct LogBloodGlucoseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log blood glucose"

    static let description = IntentDescription(
        "Record a blood glucose reading in HealthLog."
    )

    /// We want the confirmation + result dialog to read back to the user
    /// in Siri, so the intent does not open the app.
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Blood glucose (mg/dL)",
        description: "Your blood glucose reading in mg/dL.",
        inclusiveRange: (10, 1000)
    )
    var value: Double

    @Parameter(
        title: "Context",
        description: "When the reading was taken.",
        default: .unspecified
    )
    var context: GlucoseContextAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$value) mg/dL blood glucose \(\.$context)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        let measurement = Measurement(
            id: UUID().uuidString,
            kind: .glucose,
            recordedAt: Date(),
            value: .scalar(value),
            source: .manual,
            glucoseContext: context.domainValue
        )

        do {
            _ = try await deps.measurementsRepo.create(measurement)
            let shaped = value.formatted(.number.precision(.fractionLength(0 ... 1)))
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "Logged \(shaped) mg/dL blood glucose.",
                        comment: "AppIntents — blood glucose logged confirmation"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Optimistic-write contract: the value is now in the Outbox
            // and will sync on the next app foreground (incl. a transient-
            // refresh 401 the repo durably enqueued). Tell the user it
            // is saved (not lost) so an offline log still feels reliable.
            return .result(dialog: IntentCopy.queuedOffline)
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
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
