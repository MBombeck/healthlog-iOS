import SwiftUI

/// **Server-parity v1.16 — Settings → Assistant → "Kontext für den Coach".**
///
/// audit 02 · H-2 — this editor was titled "About me", which collided with the
/// Mehr → "Über mich" hub (`AboutMeScreen`): two distinct destinations rendered
/// the identical German title "Über mich". It is now titled `coachContext.title`
/// ("Kontext für den Coach" / "Coach context") so the two are unambiguous. The
/// data wiring is unchanged — this stays the coach free-text self-context editor.
///
/// Editor for the coach self-context (`GET/PUT /api/coach/about-me`): one
/// free-text field plus the three structured v1.16.0 fields (conditions,
/// allergies, coach focus). Values are sent as plain JSON and stored
/// encrypted **server-side**; iOS keeps no local copy (drafts live in the
/// store for the screen's lifetime only).
///
/// **Server-only surface** — gates on `BackendAvailability.hasServer` like
/// `CoachMemoryScreen` (standalone → calm placeholder). The route is not
/// coach-gated server-side, so no disabled-surface branch is needed.
///
/// The server derives up to three clarifying questions after a save; they
/// render read-only at the bottom (the web composer-chip flow is a separate,
/// not-yet-adopted surface).
struct SettingsAboutMeScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: CoachAboutMeStore?
    /// COACH-3 — the question the user tapped "Answer" on; drives the inline
    /// answer sheet. `nil` when no answer is in progress.
    @State private var answeringQuestion: AnsweringQuestion?
    @State private var answerDraft: String = ""

    /// `.sheet(item:)` identity wrapper — the question text is unique within
    /// the pending set, so it doubles as the id.
    private struct AnsweringQuestion: Identifiable {
        let text: String
        var id: String {
            text
        }
    }

    var body: some View {
        Group {
            if backend.hasServer {
                connectedBody
            } else {
                List {
                    HLCloudDerivedPlaceholder(
                        variant: .inline,
                        surfaceName: String(localized: "coachContext.title"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("coachContext.title")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // W-B187 COACH-3 — share the container-owned store so a question
            // adopted from the coach chat reflects here (and vice-versa).
            guard backend.hasServer, store == nil, let container else { return }
            let s = container.coachAboutMeStore
            store = s
            if !s.didLoad { await s.load() }
        }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            if store.didLoad {
                form(store: store)
            } else if store.loadFailed {
                loadFailedState(store: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadFailedState(store: CoachAboutMeStore) -> some View {
        HLEmptyState(
            icon: "wifi.exclamationmark",
            title: "Could not load your data."
        ) {
            // UI-Standard R9 — „Erneut versuchen" ist überall `.secondary`.
            // Ein Wiederholen-Knopf nach einem Ladefehler war hier die
            // lauteste Fläche der Seite (gefüllte 48-pt-`.primary`-Fläche),
            // während dieselbe Rolle auf den Sicherheits-Screens bereits
            // zurückgenommen gerendert wurde.
            HLButton("Try again", icon: "arrow.clockwise", variant: .secondary) {
                Task { await store.load() }
            }
        }
        .containerCentered()
    }

    // MARK: - Form

    private func form(store: CoachAboutMeStore) -> some View {
        @Bindable var store = store
        return HLSettingsPage(title: "coachContext.title") {
            HLSettingsCard(
                icon: "person.text.rectangle",
                title: "About you",
                footer: "What you write here is sent to your HealthLog server, stored encrypted, and shared with the coach assistant."
            ) {
                field(
                    text: $store.aboutMe,
                    prompt: String(localized: "Describe yourself…"),
                    cap: store.maxChars,
                    lines: 3 ... 8,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.aboutYou")
            }

            HLSettingsCard(icon: "stethoscope", title: "Conditions") {
                field(
                    text: $store.conditions,
                    prompt: String(localized: "Chronic conditions"),
                    cap: store.fieldMaxChars,
                    lines: 1 ... 4,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.conditions")
            }

            HLSettingsCard(icon: "allergens", title: "Allergies & intolerances") {
                field(
                    text: $store.allergies,
                    prompt: String(localized: "Allergies or intolerances"),
                    cap: store.fieldMaxChars,
                    lines: 1 ... 4,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.allergies")
            }

            HLSettingsCard(icon: "scope", title: "Coach focus") {
                field(
                    text: $store.coachFocus,
                    prompt: String(localized: "What the coach should focus on"),
                    cap: store.fieldMaxChars,
                    lines: 1 ... 4,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.coachFocus")
            }

            saveSection(store: store)

            if !store.pendingQuestions.isEmpty {
                questionsCard(store: store)
            }
        }
    }

    /// One multiline draft field + trailing live counter. The counter turns
    /// to the bad-status tint when over the server cap (Save disables then —
    /// the server would 422).
    private func field(
        text: Binding<String>,
        prompt: String,
        cap: Int,
        lines: ClosedRange<Int>,
        store: CoachAboutMeStore
    ) -> some View {
        VStack(alignment: .trailing, spacing: HLSpace.xxs) {
            TextField(prompt, text: text, axis: .vertical)
                .font(.hlBody)
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: text.wrappedValue) { _, _ in store.clearSaveOutcome() }
            Text("\(text.wrappedValue.count)/\(cap)")
                .font(.hlCaption2)
                .foregroundStyle(text.wrappedValue.count > cap ? HLColor.statusBad : HLText.tertiary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// **UI-Standard R8/R9 (U5) — der einzige System-Knopf im gesamten
    /// Einstellungsbaum ist gefallen.** „Speichern" war hier ein roher
    /// `Button` im gefüllten System-Style, während dasselbe Verb zwei Screens
    /// weiter als `HLButton` gerendert wurde. Nach R9 ist ein
    /// „Speichern" am Formularende die abschließende Commit-Aktion des Flows
    /// und damit `.primary` — die einzige `.primary`-Fläche dieses Screens.
    /// Den Spinner im Label übernimmt `isLoading:` des Primitives.
    private func saveSection(store: CoachAboutMeStore) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLButton(
                "Save",
                variant: .primary,
                isLoading: store.isSaving,
                action: { Task { await store.save() } }
            )
            .disabled(store.isSaving || !store.hasChanges || overCap(store: store))
            .accessibilityIdentifier("settings.aboutMe.save")

            switch store.saveOutcome {
            case .idle:
                EmptyView()
            case .saved:
                Label(String(localized: "Saved"), systemImage: "checkmark.circle.fill")
                    .font(.hlFootnote)
                    .foregroundStyle(HLColor.statusOK)
            case .failed:
                Label(
                    String(localized: "Could not save — please try again."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusBad)
            }
        }
    }

    /// **COACH-3** — interactive clarifying questions: each row offers
    /// "Answer" (adopt the answer into the matching self-context field) and a
    /// dismiss (✕). Answering opens an inline sheet; dismissing removes the
    /// question. Both are optimistic + outbox-backed via the store.
    private func questionsCard(store: CoachAboutMeStore) -> some View {
        // R2 — der Footer („Beantworte eine Frage, um sie in deinen Kontext zu
        // übernehmen, oder verwirf sie.") erzählte die zwei Zeilen darunter
        // nach, die genau „Antworten" und „Verwerfen" heißen. Bedien-
        // Nacherzählungen sind verboten; die Abdeck-Probe fällt eindeutig aus.
        HLSettingsCard(
            icon: "questionmark.bubble",
            title: "coach.questions.title"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                ForEach(store.pendingQuestions, id: \.self) { question in
                    questionRow(question, store: store)
                }
                questionOutcomeNote(store: store)
            }
        }
        .sheet(item: $answeringQuestion) { item in
            answerSheet(question: item.text, store: store)
        }
    }

    private func questionRow(_ question: String, store: CoachAboutMeStore) -> some View {
        let isInFlight = store.inFlightQuestions.contains(question)
        return VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "sparkles")
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(.tint)
                Text(question)
                    .font(.hlSubhead)
                    .foregroundStyle(HLText.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isInFlight {
                    ProgressView().controlSize(.mini)
                }
            }
            // UI-Standard R8 — die zwei rohen System-Knöpfe („Antworten" mit
            // `.bordered`, „Verwerfen" mit `.borderless`) sind je eine Zeile
            // geworden: in einer Karte ist eine Aktion eine Zeile, nicht ein
            // Knopf. Das Trailing-Glyph wählt jetzt `presents:` — „Antworten"
            // öffnet ein Sheet (`pencil`), „Verwerfen" löst direkt aus und
            // führt nirgendwohin (kein Glyph).
            HLSettingsActionRow(
                title: "coach.questions.answer",
                presents: .sheet,
                action: {
                    answerDraft = ""
                    answeringQuestion = AnsweringQuestion(text: question)
                }
            )
            .disabled(isInFlight)
            .accessibilityIdentifier("settings.aboutMe.question.answer")

            HLSettingsActionRow(
                title: "coach.questions.dismiss",
                labelTintOverride: HLText.secondary,
                presents: .confirm,
                action: { Task { await store.dismissQuestion(question) } }
            )
            .disabled(isInFlight)
            .accessibilityIdentifier("settings.aboutMe.question.dismiss")
        }
        .padding(.bottom, HLSpace.xs)
    }

    @ViewBuilder
    private func questionOutcomeNote(store: CoachAboutMeStore) -> some View {
        switch store.questionOutcome {
        case .idle:
            EmptyView()
        case .adopted:
            Label(String(localized: "coach.questions.adopted"), systemImage: "checkmark.circle.fill")
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusOK)
        case .dismissed:
            Label(String(localized: "coach.questions.dismissed"), systemImage: "checkmark.circle")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
        case .failed:
            Label(String(localized: "coach.questions.failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusBad)
        }
    }

    /// Inline answer entry for one clarifying question. Adopting folds the
    /// answer into the matching self-context field server-side.
    private func answerSheet(question: String, store: CoachAboutMeStore) -> some View {
        NavigationStack {
            HLSettingsPage(title: "coach.questions.answer.title") {
                HLSettingsCard(icon: "questionmark.bubble", title: "coach.questions.answer.title") {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        // The clarifying question is runtime text, so it renders
                        // as content (not the card's LocalizedStringKey title).
                        Text(question)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        answerField(store: store)
                    }
                }

                rememberButton(question: question, store: store)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { answeringQuestion = nil }
                }
            }
        }
        .hlSheetPresentation(.form)
        .presentationBackground(HLColor.surface)
    }

    private func answerField(store: CoachAboutMeStore) -> some View {
        VStack(alignment: .trailing, spacing: HLSpace.xxs) {
            TextField(
                String(localized: "coach.questions.answer.prompt"),
                text: $answerDraft,
                axis: .vertical
            )
            .font(.hlBody)
            .lineLimit(2 ... 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.aboutMe.question.answerField")
            Text("\(answerDraft.count)/\(store.fieldMaxChars)")
                .font(.hlCaption2)
                .foregroundStyle(answerDraft.count > store.fieldMaxChars ? HLColor.statusBad : HLText.tertiary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    /// UI-Standard R9 — der Commit des Antwort-Sheets. War ein roher
    /// `.borderedProminent`-Knopf; als abschließende Aktion dieses (eigenen)
    /// Screens ist er `HLButton(variant: .primary)`.
    private func rememberButton(question: String, store: CoachAboutMeStore) -> some View {
        HLButton("coach.questions.remember", variant: .primary) {
            let q = question
            let a = answerDraft
            answeringQuestion = nil
            Task { await store.adoptQuestion(q, answer: a) }
        }
        .disabled(
            answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || answerDraft.count > store.fieldMaxChars
        )
        .accessibilityIdentifier("settings.aboutMe.question.remember")
    }

    private func overCap(store: CoachAboutMeStore) -> Bool {
        store.aboutMe.count > store.maxChars
            || store.conditions.count > store.fieldMaxChars
            || store.allergies.count > store.fieldMaxChars
            || store.coachFocus.count > store.fieldMaxChars
    }
}

#Preview("SettingsAboutMeScreen") {
    NavigationStack {
        SettingsAboutMeScreen()
    }
}
