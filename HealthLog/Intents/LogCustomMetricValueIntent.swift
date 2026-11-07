import AppIntents
import Foundation

/// **1.5 SHORTCUT (#155, public #1295)** — log a value for one of the
/// person's own metrics from Shortcuts, Siri or the Action button, without
/// opening the app.
///
/// Writes through ``CustomMetricsRepository/createEntry(metricID:_:)``, the
/// path the in-app entry sheet uses: idempotency key, and on a network error
/// the encrypted outbox the app drains on the next foreground. No new endpoint,
/// no second write path.
///
/// **Device lock.** The confirmation names the metric, and metric names are
/// whatever the person typed, so Siri asks for Face ID or the passcode first
/// on a locked iPhone (as the two read intents do). That is also why the
/// in-app lock needs no extra gate here: the system already asked the owner.
struct LogCustomMetricValueIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a value"

    static let description = IntentDescription(
        "Log a value for one of your custom metrics in HealthLog."
    )

    static let openAppWhenRun: Bool = false

    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(
        title: "Custom metric",
        description: "Which of your custom metrics to log."
    )
    var metric: CustomMetricEntity

    @Parameter(
        title: "Value",
        description: "Rounded to the decimal places set for the metric."
    )
    var value: Double

    @Parameter(
        title: "Date",
        description: "When the value was measured. Leave empty for now."
    )
    var date: Date?

    @Parameter(
        title: "Note",
        description: "An optional note for this value.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$value) for \(\.$metric)") {
            \.$date
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await LogCustomMetricValue.run(
            metric: metric,
            value: value,
            date: date,
            note: note,
            deps: IntentDependencies.resolve()
        )
        return .result(dialog: IntentDialog(outcome.resource))
    }
}

/// The intent's logic without the App-Intents runtime: checks, the write, and
/// one answer for every way it can end. Each ``Outcome`` has its own sentence,
/// so no run ends in silence or in a system error.
enum LogCustomMetricValue {
    enum Outcome: Equatable {
        case signedOut
        /// Not a finite number.
        case invalidValue
        /// In the future, or older than the server's 50-year window.
        case invalidDate
        case noteTooLong
        /// `shown` is the value as written, with the metric's unit.
        case logged(name: String, shown: String)
        /// On the outbox; the app sends it later.
        case queued(HLError)
        /// 404: the metric was deleted since the shortcut was set up.
        case metricGone
        /// 403: refused for this account (`module.disabled` or a narrow scope).
        case disabled
        case failed
    }

    /// The server's `ENTRY_MAX_AGE_MS` (50 years) for `measuredAt`.
    static let maximumAge: TimeInterval = 50 * 365.25 * 24 * 60 * 60
    /// A date a few seconds ahead (clock skew, a "now" picked a moment ago) is
    /// taken as now rather than refused.
    static let futureTolerance: TimeInterval = 60

    @MainActor
    static func run(
        metric: CustomMetricEntity,
        value: Double,
        date: Date?,
        note: String?,
        deps: IntentDependencies.Resolved,
        now: Date = .now
    ) async -> Outcome {
        guard IntentDependencies.isSignedIn(deps) else { return .signedOut }
        guard value.isFinite else { return .invalidValue }

        let measuredAt = date ?? now
        if measuredAt.timeIntervalSince(now) > futureTolerance { return .invalidDate }
        if now.timeIntervalSince(measuredAt) > maximumAge { return .invalidDate }
        let sentAt = min(measuredAt, now)

        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.count <= CustomMetricValidation.noteMaxLength else { return .noteTooLong }

        let rounded = roundedValue(value, decimals: metric.decimals)
        let body = CustomMetricEntryCreate(
            value: rounded,
            measuredAt: ISO8601DateFormatter.fractional.string(from: sentAt),
            note: trimmed.isEmpty ? nil : trimmed
        )
        do {
            try await deps.customMetricsRepo.createEntry(metricID: metric.id, body)
            let shown = CustomMetricFormat.text(value: rounded, unit: metric.unit, decimals: metric.decimals)
            return .logged(name: metric.name, shown: shown)
        } catch let error as HLError {
            return outcome(for: error)
        } catch {
            return .failed
        }
    }

    /// The metric's `decimals` (server-capped `0...6`, clamped like
    /// ``CustomMetricFormat``), half away from zero, as the entry sheet shows
    /// it. Without `decimals` the value goes as given.
    static func roundedValue(_ value: Double, decimals: Int?) -> Double {
        guard let decimals else { return value }
        let factor = pow(10, Double(min(max(decimals, 0), 6)))
        return (value * factor).rounded(.toNearestOrAwayFromZero) / factor
    }

    static func outcome(for error: HLError) -> Outcome {
        if error.shouldPersistToOutbox { return .queued(error) }
        if error.isModuleDisabled { return .disabled }
        if case let .server(status, _, _) = error {
            if status == 404 { return .metricGone }
            if status == 403 { return .disabled }
        }
        return .failed
    }
}

extension LogCustomMetricValue.Outcome {
    var resource: LocalizedStringResource {
        switch self {
        case .signedOut:
            LocalizedStringResource(
                "Open HealthLog and sign in first, then try again.",
                comment: "AppIntents — not signed in"
            )
        case .invalidValue:
            IntentCopy.measurementOutOfRange
        case .invalidDate:
            LocalizedStringResource(
                "intents.logCustomMetric.dateInvalid",
                defaultValue: "That date doesn't work. Choose a time that isn't in the future.",
                comment: "AppIntents — custom metric value: date in the future or more than 50 years back"
            )
        case .noteTooLong:
            LocalizedStringResource(
                "intents.logCustomMetric.noteTooLong",
                defaultValue: "The note is too long (max. 2,000 characters).",
                comment: "AppIntents — custom metric value: note over the 2000-character limit"
            )
        case let .logged(name, shown) where name.isEmpty:
            LocalizedStringResource(
                "intents.logCustomMetric.confirmedUnnamed",
                defaultValue: "Logged \(shown).",
                comment: "AppIntents — custom metric value logged, metric name unknown; %@ is the value with unit"
            )
        case let .logged(name, shown):
            LocalizedStringResource(
                "intents.logCustomMetric.confirmed",
                defaultValue: "Logged \(shown) for \(name).",
                comment: "AppIntents — custom metric value logged; %1$@ value with unit, %2$@ metric name"
            )
        case let .queued(error):
            IntentCopy.queuedResource(after: error)
        case .metricGone:
            LocalizedStringResource(
                "intents.logCustomMetric.metricGone",
                defaultValue: "This metric no longer exists. Choose another one in the shortcut.",
                comment: "AppIntents — custom metric value: the metric was deleted (404)"
            )
        case .disabled:
            LocalizedStringResource("feature_disabled.title")
        case .failed:
            LocalizedStringResource(
                "Couldn't save that right now. Please try again in the app.",
                comment: "AppIntents — non-retriable write failure"
            )
        }
    }
}
