import AppIntents
import Foundation

/// **W-B187 QOL-1** — the per-medication READ intent: *"Did I take
/// Lisinopril?"*
///
/// The shipped `MedicationComplianceQueryIntent` answers the *global*
/// "have I taken my meds today?" (an aggregate count). This is the
/// *specific* counterpart the operator's wishlist names — ask about ONE
/// medication by name and get a spoken / Spotlight answer ("Yes, you took
/// Lisinopril at 08:12" / "Not yet today").
///
/// **Read-only, server-first, launch-independent.** Resolves the same
/// shared `IntentDependencies` stack the write intents use and reads
/// today's intake list (`MedicationsRepository.todayIntakes()`) — the
/// SAME server-canonical `?scope=today` rows the in-app medication cards
/// paint. No new endpoint, no client recompute of compliance, no parallel
/// read path. On a network error it degrades to a soft "couldn't check"
/// dialog rather than a hard failure (a Siri/Spotlight read must never
/// throw a raw error at the user).
///
/// The medication is resolved via the existing `MedicationEntityQuery`
/// (defined alongside `MarkMedicationTakenIntent`) so Siri / Spotlight can
/// offer the user's medications by name.
struct DidITakeMedicationIntent: AppIntent {
    static let title: LocalizedStringResource = "Did I take this medication?"

    static let description = IntentDescription(
        "Tells you whether you've already taken a specific medication today."
    )

    static let openAppWhenRun: Bool = false

    /// Read-only — surface it as a query in Spotlight / Siri.
    static let isDiscoverable: Bool = true

    @Parameter(
        title: "Medication",
        description: "The medication to check."
    )
    var medication: MedicationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Did I take \(\.$medication) today?")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else {
            return .result(dialog: IntentCopy.signInRequired)
        }

        do {
            let intakes = try await deps.medicationsRepo.todayIntakes()
            let verdict = DidITakeMedicationCopy.verdict(
                for: medication.id,
                in: intakes
            )
            return .result(dialog: DidITakeMedicationCopy.dialog(name: medication.name, verdict: verdict))
        } catch {
            return .result(dialog: DidITakeMedicationCopy.unavailable)
        }
    }
}

/// **W-B187 QOL-1 — pure, localized copy + verdict logic for the per-med
/// query.**
///
/// Split out so the (id, today-intakes) → spoken-answer mapping is
/// unit-testable without an AppIntent `perform()` or a live server. The
/// three buckets the user cares about — *taken*, *not yet today*, and
/// *no dose scheduled today* — each get a distinct, natural line in
/// EN + DE.
enum DidITakeMedicationCopy {
    /// What today's intake list says about one medication.
    enum Verdict: Equatable {
        /// At least one slot is marked taken; carries the most recent
        /// `takenAt` so the dialog can say *when*.
        case taken(at: Date?)
        /// The medication has a slot today but none is taken yet
        /// (pending / snoozed / skipped).
        case notYet
        /// No intake row for this medication today (nothing scheduled).
        case noneScheduled
    }

    /// Reduce today's intake rows to a verdict for `medicationId`. Pure +
    /// testable. A medication is "taken" if ANY of its today slots is
    /// `.taken`; the reported instant is the latest non-nil `takenAt`.
    static func verdict(for medicationId: String, in intakes: [MedicationIntake]) -> Verdict {
        let mine = intakes.filter { $0.medicationId == medicationId }
        guard mine.isEmpty == false else { return .noneScheduled }
        let takenSlots = mine.filter { $0.status == .taken }
        guard takenSlots.isEmpty == false else { return .notYet }
        let latest = takenSlots.compactMap(\.takenAt).max()
        return .taken(at: latest)
    }

    /// Build the spoken / Spotlight dialog for the verdict on `name`.
    static func dialog(name: String, verdict: Verdict) -> IntentDialog {
        IntentDialog(resource(name: name, verdict: verdict))
    }

    /// The pure `LocalizedStringResource` the dialog wraps — the unit-tested
    /// seam. Picks the taken / not-yet / nothing-scheduled variant.
    static func resource(name: String, verdict: Verdict) -> LocalizedStringResource {
        switch verdict {
        case let .taken(at):
            if let at {
                let time = at.formatted(date: .omitted, time: .shortened)
                return LocalizedStringResource(
                    "intents.didITake.taken.at",
                    defaultValue: "Yes — you took \(name) at \(time).",
                    comment: "AppIntents — per-med query, taken with time; %1$@ name, %2$@ time"
                )
            }
            return LocalizedStringResource(
                "intents.didITake.taken",
                defaultValue: "Yes — you've already taken \(name) today.",
                comment: "AppIntents — per-med query, taken (no recorded time); %@ is the medication name"
            )
        case .notYet:
            return LocalizedStringResource(
                "intents.didITake.notYet",
                defaultValue: "No — you haven't taken \(name) yet today.",
                comment: "AppIntents — per-med query, not taken yet; %@ is the medication name"
            )
        case .noneScheduled:
            return LocalizedStringResource(
                "intents.didITake.noneScheduled",
                defaultValue: "\(name) isn't scheduled for today.",
                comment: "AppIntents — per-med query, nothing scheduled today; %@ is the medication name"
            )
        }
    }

    /// The server fetch failed — soft, retry-from-app line.
    static var unavailable: IntentDialog {
        IntentDialog(
            LocalizedStringResource(
                "intents.didITake.unavailable",
                defaultValue: "I couldn't check that right now. Please open HealthLog and try again.",
                comment: "AppIntents — per-med query, server unreachable"
            )
        )
    }
}
