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
/// **Server-only surface.** The route is not coach-gated server-side, so no disabled-surface branch is needed.
///
/// The server derives up to three clarifying questions after a save; they
/// render read-only at the bottom (the web composer-chip flow is a separate,
/// not-yet-adopted surface).
struct SettingsAboutMeScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: CoachAboutMeStore?
    /// The question the user tapped "Answer" on; drives the inline
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
        connectedBody
            .navigationTitle("coachContext.title")
            .navigationBarTitleDisplayMode(.inline)
            // Saving is the check mark in the bar (Z17). The page goes back
            // unless the server asked clarifying questions to show below.
            .hlConfirmBar(saveAction, identifier: "settings.aboutMe.save", hidesUntilChanged: true)
            .task {
                // Share the container-owned store so a question
                // adopted from the coach chat reflects here (and vice-versa).
                guard store == nil, let container else { return }
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
        HLErrorState("Could not load your data.") {
            await store.load()
        }
        .padding(.horizontal, HLLayout.pageMargin)
    }

    // MARK: - Form

    private func form(store: CoachAboutMeStore) -> some View {
        @Bindable var store = store
        return HLPage {
            HLCard(
                "About you",
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

            HLCard("Conditions") {
                field(
                    text: $store.conditions,
                    prompt: String(localized: "Chronic conditions"),
                    cap: store.fieldMaxChars,
                    lines: 1 ... 4,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.conditions")
            }

            HLCard("Allergies & intolerances") {
                field(
                    text: $store.allergies,
                    prompt: String(localized: "Allergies or intolerances"),
                    cap: store.fieldMaxChars,
                    lines: 1 ... 4,
                    store: store
                )
                .accessibilityIdentifier("settings.aboutMe.allergies")
            }

            HLCard("Coach focus") {
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

    private var saveAction: HLSheetAction {
        guard let store, store.didLoad else { return .none }
        return .save(isEnabled: store.hasChanges && !store.isSaving && !overCap(store: store)) {
            await store.save()
            return store.saveOutcome == .saved && store.pendingQuestions.isEmpty
        }
    }

    /// What the last save produced, under the fields it saved.
    @ViewBuilder
    private func saveSection(store: CoachAboutMeStore) -> some View {
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

    /// Interactive clarifying questions: each row offers
    /// "Answer" (adopt the answer into the matching self-context field) and a
    /// dismiss (✕). Answering opens an inline sheet; dismissing removes the
    /// question. Both are optimistic + outbox-backed via the store.
    private func questionsCard(store: CoachAboutMeStore) -> some View {
        // Der Footer („Beantworte eine Frage, um sie in deinen Kontext zu
        // übernehmen, oder verwirf sie.") erzählte die zwei Zeilen darunter
        // nach, die genau „Antworten" und „Verwerfen" heißen. Bedien-
        // Nacherzählungen sind verboten; die Abdeck-Probe fällt eindeutig aus.
        HLCard("coach.questions.title") {
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
                    .hlText(.prose)
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
                .hlText(.note)
        case .failed:
            Label(String(localized: "coach.questions.failed"), systemImage: "exclamationmark.triangle.fill")
                .font(.hlFootnote)
                .foregroundStyle(HLColor.statusBad)
        }
    }

    /// Inline answer entry for one clarifying question. Adopting folds the
    /// answer into the matching self-context field server-side.
    private func answerSheet(question: String, store: CoachAboutMeStore) -> some View {
        HLSheetScaffold(
            "coach.questions.answer.title",
            action: .confirm("coach.questions.remember", isEnabled: canRemember(store: store)) {
                let answer = answerDraft
                Task { await store.adoptQuestion(question, answer: answer) }
                return true
            },
            isDirty: !answerDraft.isEmpty
        ) {
            HLPage {
                HLCard {
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        // The clarifying question is runtime text, so it renders
                        // as content (not the card's LocalizedStringKey title).
                        Text(question)
                            .hlText(.prose)
                            .fixedSize(horizontal: false, vertical: true)
                        answerField(store: store)
                    }
                }
            }
        }
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
    private func canRemember(store: CoachAboutMeStore) -> Bool {
        !answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && answerDraft.count <= store.fieldMaxChars
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
