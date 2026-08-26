import AppIntents
import Foundation

/// **v0.10.0 W-Mood-B** — "Log my mood" Siri / Shortcuts intent.
///
/// Records a single mood check-in through the **same** `MoodRepository.log`
/// path the in-app capture sheet uses: optimistic server POST with an
/// idempotency key, falling back to the Outbox on a network error so the
/// entry replays exactly-once on the next app foreground. No parallel write
/// path — the missing sibling of the existing `LogBloodGlucoseIntent` /
/// `LogBloodPressureIntent` write intents.
///
/// Runs without launching the full app (`openAppWhenRun = false`) —
/// dependencies resolve from the Keychain + a recovered Outbox via
/// ``IntentDependencies``. When the user is not signed in we surface a
/// friendly dialog rather than firing a doomed 401.
///
/// "Hey Siri, log my mood" → Siri resolves the level (`great … lousy`) →
/// writes → reads back a calm one-line confirmation.
struct LogMoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log mood"

    static let description = IntentDescription(
        "Record how you're feeling in HealthLog."
    )

    /// We want the confirmation dialog to read back to the user in Siri, so
    /// the intent does not open the app.
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Mood",
        description: "How you're feeling right now."
    )
    var level: MoodLevelAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Log my mood as \(\.$level)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        do {
            _ = try await deps.moodRepo.log(
                score: level.score,
                tags: [],
                note: nil
            )
            return .result(
                dialog: IntentDialog(
                    LocalizedStringResource(
                        "Logged your mood as \(level.spokenName).",
                        comment: "AppIntents — mood logged confirmation"
                    )
                )
            )
        } catch let error as HLError where error.shouldPersistToOutbox {
            // Optimistic-write contract: the entry is now in the Outbox and
            // will sync on the next app foreground (incl. a transient-refresh
            // 401 the repo durably enqueued). Tell the user it is saved
            // (not lost) so an offline log still feels reliable.
            return .result(dialog: IntentCopy.queuedOffline)
        } catch {
            return .result(dialog: IntentCopy.writeFailed)
        }
    }
}

/// Mood-level picker surfaced to Siri / Shortcuts. Maps onto the domain
/// ``ServerMoodLevel`` (1…5) so the server stores the same level the in-app
/// 5-emoji picker writes.
enum MoodLevelAppEnum: String, AppEnum {
    case lousy
    case bad
    case okay
    case good
    case great

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Mood"
    )

    static let caseDisplayRepresentations: [MoodLevelAppEnum: DisplayRepresentation] = [
        .lousy: DisplayRepresentation(title: "Lousy"),
        .bad: DisplayRepresentation(title: "Bad"),
        .okay: DisplayRepresentation(title: "Okay"),
        .good: DisplayRepresentation(title: "Good"),
        .great: DisplayRepresentation(title: "Great")
    ]

    /// Build from a 1…5 HealthLog score (clamped). Lets the interactive mood
    /// widget construct a `LogMoodIntent` from a tapped face button.
    init(score: Int) {
        switch max(1, min(5, score)) {
        case 1: self = .lousy
        case 2: self = .bad
        case 3: self = .okay
        case 4: self = .good
        default: self = .great
        }
    }

    /// Bridge to the domain enum so the score passed to `MoodRepository.log`
    /// matches the in-app capture exactly.
    var serverLevel: ServerMoodLevel {
        switch self {
        case .lousy: .lousy
        case .bad: .bad
        case .okay: .okay
        case .good: .good
        case .great: .great
        }
    }

    /// HealthLog mood score (1…5) for the repository call.
    var score: Int {
        serverLevel.score
    }

    /// Localized lower-case name woven into the spoken confirmation dialog
    /// ("Logged your mood as good.").
    var spokenName: LocalizedStringResource {
        switch self {
        case .lousy: LocalizedStringResource("lousy", comment: "AppIntents — spoken mood level")
        case .bad: LocalizedStringResource("bad", comment: "AppIntents — spoken mood level")
        case .okay: LocalizedStringResource("okay", comment: "AppIntents — spoken mood level")
        case .good: LocalizedStringResource("good", comment: "AppIntents — spoken mood level")
        case .great: LocalizedStringResource("great", comment: "AppIntents — spoken mood level")
        }
    }
}
