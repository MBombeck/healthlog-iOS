import SwiftUI

/// **G2/G3 (AUDIT-onboarding) — onboarding anamnesis + goals parity.**
///
/// Web onboarding (step 3) offers an optional anamnesis card (chronic
/// conditions + allergies/intolerances) plus a goals capture ("what do you
/// want to track?").
///
/// **Two canonical stores, no parallel write paths (audit 02 · H-2b).**
/// - **Conditions + goals** → `CoachAboutMeStore` → `PUT /api/coach/about-me`
///   (encrypted free-text self-context; the same store the Settings → Coach
///   context editor uses).
/// - **Allergies** → the structured FHIR `AllergyIntolerance` store
///   (`AllergiesStore` → `POST /api/allergies`), which is exactly what
///   "Mehr → Über mich → Allergien" (`AllergiesListScreen`) reads. Before the
///   fix onboarding wrote allergies into the coach free-text field, so what a
///   user typed here never appeared in the real allergies surface — it looked
///   lost. Both surfaces now share ONE source of truth. Each non-empty line /
///   comma-separated entry becomes one `AllergyDTO` (default category OTHER,
///   type ALLERGY, status ACTIVE); substances already on file are skipped so a
///   re-onboard never duplicates a record. The write is optimistic +
///   outbox-backed exactly like the in-app allergy editor.
///
/// **Skippable, never a gate.** A user can finish onboarding with everything
/// blank and fill it later in Settings → Assistant → About me. "Continue"
/// saves only when something was typed; "Later" advances untouched.
///
/// **Server-only surface.** The about-me route lives on the server, so this
/// step is reached on the server branch only (standalone has no
/// server). The flow inserts it between the AI-source step and `done`.
struct AnamnesisStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.appContainer) private var container
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store: CoachAboutMeStore?
    /// audit 02 · H-2b — the structured FHIR allergies store (the one
    /// `AllergiesListScreen` reads). Onboarding allergies are created here so the
    /// onboarding intake and "Über mich → Allergien" share one source of truth.
    @State private var allergiesStore: AllergiesStore?
    @State private var conditions: String = ""
    @State private var allergies: String = ""
    @State private var goals: String = ""
    @State private var isSaving = false
    @State private var appeared = false
    /// audit 02 · M-5 — set when a save fails so the step surfaces the error
    /// instead of silently advancing as if the entry was persisted.
    @State private var saveFailed = false
    /// 08-10 — how many allergy entries the server refused, out of how many were
    /// attempted. `nil` when nothing was attempted or everything landed. The
    /// allergy loop used to discard every result (`_ = await …create(…)`), so a
    /// half-written intake reported the same complete success as a whole one.
    @State private var partialSave: AllergySaveResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HLSpace.xl) {
                header
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)

                cards
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : entranceOffset)
                    .animation(cardAnimation, value: appeared)

                Spacer(minLength: HLSpace.xxl)
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.top, HLSpace.xxl)
        }
        .background(HLColor.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HLSpace.sm) {
                if let partialSave {
                    // Counts, never substances: the entries themselves are
                    // health data and stay in the field the user typed them in,
                    // which is also what makes the retry a retry.
                    Text(verbatim: Self.partialSaveMessage(
                        failed: partialSave.failed.count,
                        attempted: partialSave.attempted
                    ))
                    .font(.hlCaption)
                    .foregroundStyle(HLColor.statusBad)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.anamnesis.partialFailure")
                }
                if saveFailed {
                    Text("onboarding.save.failed")
                        .font(.hlCaption)
                        .foregroundStyle(HLColor.statusBad)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.anamnesis.saveFailed")
                }
                HLButton(
                    String(localized: "Continue"),
                    variant: .primary,
                    size: .large,
                    isLoading: isSaving
                ) {
                    Task { await saveThenContinue() }
                }
                .accessibilityIdentifier("onboarding.anamnesis.continue")
                HLButton(String(localized: "Later"), variant: .ghost) {
                    onSkip()
                }
                .accessibilityIdentifier("onboarding.anamnesis.skip")
            }
            .padding(.horizontal, HLSpace.xl)
            .padding(.bottom, HLSpace.xxxl)
            .background(HLColor.background)
        }
        .task { await prepareStore() }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            Image(systemName: "list.clipboard")
                // Canonical onboarding hero glyph (`HLIconSize.display`, mono).
                .font(.hlIcon(HLIconSize.display))
                .foregroundStyle(HLText.primary)
            Text(String(localized: "onboarding.anamnesis.title"))
                .font(.hlTitle1)
                .foregroundStyle(HLText.primary)
            Text(String(localized: "onboarding.anamnesis.subtitle"))
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            anamnesisCard(
                icon: "scope",
                title: String(localized: "onboarding.anamnesis.goals.title"),
                prompt: String(localized: "onboarding.anamnesis.goals.prompt"),
                text: $goals,
                identifier: "onboarding.anamnesis.goals"
            )
            anamnesisCard(
                icon: "stethoscope",
                title: String(localized: "onboarding.anamnesis.conditions.title"),
                prompt: String(localized: "onboarding.anamnesis.conditions.prompt"),
                text: $conditions,
                identifier: "onboarding.anamnesis.conditions"
            )
            anamnesisCard(
                icon: "allergens",
                title: String(localized: "onboarding.anamnesis.allergies.title"),
                prompt: String(localized: "onboarding.anamnesis.allergies.prompt"),
                text: $allergies,
                identifier: "onboarding.anamnesis.allergies"
            )
            Text(String(localized: "onboarding.anamnesis.footer"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func anamnesisCard(
        icon: String,
        title: String,
        prompt: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(spacing: HLSpace.sm) {
                    Image(systemName: icon)
                        .font(.hlIcon(HLIconSize.rowAction))
                        .foregroundStyle(HLText.secondary)
                    Text(title)
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                }
                TextField(prompt, text: text, axis: .vertical)
                    .font(.hlBody)
                    .lineLimit(1 ... 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(identifier)
            }
        }
    }

    // MARK: - Persist

    private func prepareStore() async {
        guard store == nil, let container else { return }
        let s = container.coachAboutMeStore
        store = s
        let a = container.allergiesStore
        allergiesStore = a
        // Hydrate drafts from any existing server state so re-onboarding
        // doesn't blank a value the user already saved.
        if !s.didLoad { await s.load() }
        conditions = s.conditions
        goals = s.coachFocus
        // audit 02 · H-2b — allergies live in the FHIR store now, so prefill the
        // draft from those structured records (joined by ", "). This keeps the
        // field truthful on re-onboard and — together with the skip-existing
        // guard in `persistAllergies` — makes an unchanged Continue a no-op.
        if a.records.isEmpty { await a.load() }
        allergies = a.records.map(\.substance).joined(separator: ", ")
    }

    /// Persists the drafts to their two canonical stores (audit 02 · H-2b):
    /// conditions + goals → `CoachAboutMeStore` (`PUT /api/coach/about-me`),
    /// allergies → the structured FHIR `AllergiesStore` (`POST /api/allergies`).
    /// A blank-everything step is a no-op save (we still advance). Failures don't
    /// block onboarding — both writes are outbox-backed and the user can retry
    /// later (Settings → Coach context / Über mich → Allergien).
    private func saveThenContinue() async {
        let trimmedConditions = conditions.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAllergies = allergies.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoals = goals.trimmingCharacters(in: .whitespacesAndNewlines)

        let nothingEntered = trimmedConditions.isEmpty
            && trimmedAllergies.isEmpty
            && trimmedGoals.isEmpty
        guard !nothingEntered else {
            onNext()
            return
        }

        isSaving = true
        saveFailed = false
        partialSave = nil
        defer { isSaving = false }

        // 1. Allergies → the FHIR store the "Über mich → Allergien" surface reads.
        //    Outbox-backed (an offline create is a durable success), but a
        //    refusal is a refusal: 08-10 collects each one instead of discarding
        //    it, so a save that wrote three of five entries can say so.
        let allergyResult = await persistAllergies(trimmedAllergies)

        // 2. Conditions + goals → the coach free-text self-context store.
        var conditionsFailed = false
        if let store {
            store.conditions = trimmedConditions
            store.coachFocus = trimmedGoals
            await store.save()
            // audit 02 · M-5 — the write is outbox-backed, but a same-session
            // failure was previously swallowed (we advanced as if saved). Surface
            // it: keep the user on the step so they can retry Continue, or tap
            // "Later" to skip. `CoachAboutMeStore.save()` reports `.failed` on error.
            conditionsFailed = store.saveOutcome == .failed
        }

        switch Self.disclosure(allergies: allergyResult, conditionsFailed: conditionsFailed) {
        case .complete:
            onNext()
        case .partial:
            // Only the refused entries stay in the field, so Continue retries
            // exactly what did not land and nothing that did.
            allergies = allergyResult.failed.joined(separator: ", ")
            partialSave = allergyResult
        case .failed:
            if !allergyResult.failed.isEmpty {
                allergies = allergyResult.failed.joined(separator: ", ")
                partialSave = allergyResult
            }
            saveFailed = true
        }
    }

    // MARK: - Save outcome (08-10)

    /// What one Continue actually achieved, per store.
    struct AllergySaveResult: Equatable {
        /// How many substances were sent (already-known ones are not attempted).
        let attempted: Int
        /// The substances the store refused, in the order they were typed.
        let failed: [String]

        /// Deliberately not spelled `none`: at a call site returning
        /// `AllergySaveResult` that would read as `Optional.none`.
        static let nothingAttempted = AllergySaveResult(attempted: 0, failed: [])
    }

    /// What the step must say, given both writes.
    enum SaveDisclosure: Equatable {
        /// Everything that was attempted landed.
        case complete
        /// The free-text context landed; some allergy entries did not.
        case partial(failed: Int)
        /// The free-text context did not land.
        case failed
    }

    /// The pure aggregation — deliberately not "read a global error after the
    /// operation". Advancing is reserved for the one case in which nothing was
    /// refused; a partial result is a distinct answer, not a rounded success.
    nonisolated static func disclosure(
        allergies: AllergySaveResult,
        conditionsFailed: Bool
    ) -> SaveDisclosure {
        if conditionsFailed { return .failed }
        return allergies.failed.isEmpty ? .complete : .partial(failed: allergies.failed.count)
    }

    /// A localized, redacted summary: counts only. The substances are the
    /// user's health data and are never composed into a message — they stay in
    /// the field, which is both the disclosure and the retry.
    nonisolated static func partialSaveMessage(failed: Int, attempted: Int) -> String {
        String(format: String(localized: "onboarding.anamnesis.partialSave"), failed, attempted)
    }

    /// Splits the allergies free-text into individual substances (one per line or
    /// comma) and creates a structured `AllergyDTO` for each that isn't already on
    /// file. Case-insensitive de-dup against the loaded records keeps a re-onboard
    /// from duplicating a record; each create is optimistic + outbox-backed.
    private func persistAllergies(_ text: String) async -> AllergySaveResult {
        guard let allergiesStore else { return .nothingAttempted }
        let existing = Set(allergiesStore.records.map { $0.substance.lowercased() })
        var seen = existing
        var attempted = 0
        var failed: [String] = []
        for substance in Self.parseSubstances(text) {
            let key = substance.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            attempted += 1
            // `create` answers `nil` on refusal. 08-10 — that answer is now
            // kept. Awaiting each one in turn is deliberate: a `TaskGroup` here
            // would race the store's own de-duplication.
            if await allergiesStore.create(AllergyCreate(substance: substance)) == nil {
                failed.append(substance)
            }
        }
        return AllergySaveResult(attempted: attempted, failed: failed)
    }

    /// Parse a free-text allergies blob into trimmed, non-empty substance labels,
    /// split on newlines and commas. Each label is capped at the server's 160-char
    /// `substance` limit so an over-long line degrades gracefully instead of 422-ing.
    static func parseSubstances(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(160)) }
    }

    // MARK: - Entrance

    private var entranceOffset: CGFloat {
        reduceMotion ? 0 : 14
    }

    private var cardAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(response: 0.3, dampingFraction: 0.85).delay(0.05)
    }
}
