import AppIntents
import Foundation

/// **v0.7.1 W-APPINTENTS** — "Log blood pressure" Siri / Shortcuts intent.
///
/// Records a systolic/diastolic pair through the same
/// `MeasurementsRepository.create` path the manual-entry sheet uses. The
/// repo splits the pair into the two server wire-rows internally and
/// shares one idempotency key, so an offline log replays exactly-once
/// via the Outbox. No parallel write path.
struct LogBloodPressureIntent: AppIntent {
    static let title: LocalizedStringResource = "Log blood pressure"

    static let description = IntentDescription(
        "Record a blood pressure reading (systolic / diastolic) in HealthLog."
    )

    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Systolic (mmHg)",
        description: "The upper (systolic) value in mmHg.",
        inclusiveRange: (40, 300)
    )
    var systolic: Double

    @Parameter(
        title: "Diastolic (mmHg)",
        description: "The lower (diastolic) value in mmHg.",
        inclusiveRange: (20, 200)
    )
    var diastolic: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log blood pressure \(\.$systolic) over \(\.$diastolic)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        // Guard the physiological ordering — a systolic below diastolic
        // is a transposed entry. Surface a dialog rather than persisting
        // a nonsensical pair.
        guard systolic > diastolic else {
            return .result(dialog: IntentDialog(IntentCopy.bpOrderInvalid))
        }

        let measurement = Measurement(
            id: UUID().uuidString,
            kind: .bloodPressure,
            recordedAt: Date(),
            value: .bloodPressure(systolic: systolic, diastolic: diastolic),
            source: .manual
        )

        do {
            _ = try await deps.measurementsRepo.create(measurement)
            let sys = systolic.formatted(.number.precision(.fractionLength(0)))
            let dia = diastolic.formatted(.number.precision(.fractionLength(0)))
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "Logged \(sys)/\(dia) mmHg blood pressure.",
                        comment: "AppIntents — blood pressure logged confirmation"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Durably enqueued (incl. a transient-refresh 401) — saved, not lost.
            return .result(dialog: IntentCopy.queuedOffline)
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}
