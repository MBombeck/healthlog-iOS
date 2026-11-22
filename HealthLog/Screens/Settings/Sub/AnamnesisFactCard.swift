import SwiftUI

/// **Eine Fakten-Art als Karte.**
///
/// Aufbau von oben nach unten: der aktuelle Zustand (mit Gültigkeit und
/// Provenienz), die Auswahl der Werte, das Entfernen, der Verlauf.
///
/// Die Auswahl zeigt **immer alle** erlaubten Werte dieser Art — auch wenn
/// gerade nichts erfasst ist. Ein vorausgewählter Wert gäbe es nicht: es gibt
/// keinen Standard, und einen zu unterstellen wäre bei einer Anamnese eine
/// erfundene Aussage.
struct AnamnesisFactCard: View {
    let kind: AnamnesisFactKind
    let store: AnamnesisFactsStore

    @State private var showHistory = false

    private var state: AnamnesisFactState {
        store.state(for: kind)
    }

    private var history: [AnamnesisFactRevision] {
        store.history(for: kind)
    }

    private var isPending: Bool {
        store.pendingKind == kind
    }

    var body: some View {
        // UI-Standard R2 (U6, Audit-Gruppe G10) — die drei Karten-Subtitles
        // buchstabierten ihre eigenen Auswahlknöpfe nach („Ob du rauchst — und
        // ob du früher geraucht hast." über den Knöpfen Ja/Nein/Früher).
        // Kartentitel plus Auswahlwerte tragen die Karte allein.
        HLCard(LocalizedStringKey(kind.titleKey)) {
            currentStateRow
            valueChoices
            if state.isRecorded { removeRow }
            // No history yet, no disclosure: an empty fold-out that
            // explained what would appear in it is gone.
            if !history.isEmpty { historyDisclosure }
        }
        .accessibilityIdentifier("anamnesis.card.\(kind.rawValue)")
    }

    // MARK: - Current state

    /// Der aktuelle Zustand — die Stelle, an der „nie erfasst" und „keine"
    /// sichtbar auseinanderfallen.
    @ViewBuilder
    private var currentStateRow: some View {
        switch state {
        case .neverRecorded:
            // What "never recorded" means against "none" is said
            // once, in the screen's (i), not under each of the three cards.
            HLBadge(String(localized: "anamnesis.state.neverRecorded"), icon: "questionmark.circle", tone: .neutral)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("anamnesis.state.neverRecorded.\(kind.rawValue)")

        case let .unreadable(revision):
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HLBadge(String(localized: "anamnesis.state.unreadable"), icon: "lock.slash", tone: .warning)
                Text("anamnesis.state.unreadable.hint")
                    .hlText(.rowSubtitle)
                validityLine(revision)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("anamnesis.state.unreadable.\(kind.rawValue)")

        case let .recorded(revision, value):
            VStack(alignment: .leading, spacing: HLSpace.xs) {
                HStack(spacing: HLSpace.sm) {
                    HLRowTitle(Text(LocalizedStringKey(kind.labelKey(for: value))))
                    if let provenanceKey = revision.provenance.labelKey {
                        HLBadge(
                            String(localized: String.LocalizationValue(provenanceKey)),
                            tone: revision.isCorrection ? .info : .neutral
                        )
                    }
                    Spacer(minLength: 0)
                    if isPending { ProgressView().controlSize(.mini) }
                }
                validityLine(revision)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("anamnesis.state.recorded.\(kind.rawValue)")
        }
    }

    /// „Gilt seit …" — die Effektiv-Datierung, ohne die der aktuelle Stand nur
    /// die halbe Aussage wäre.
    private func validityLine(_ revision: AnamnesisFactRevision) -> some View {
        Text(revision.validityText)
            .hlText(.rowSubtitle)
    }

    // MARK: - Choices

    private var valueChoices: some View {
        VStack(spacing: 0) {
            ForEach(kind.allowedValues, id: \.rawValue) { value in
                choiceRow(value)
            }
        }
        .disabled(store.pendingKind != nil)
    }

    private func choiceRow(_ value: AnamnesisFactValue) -> some View {
        let isSelected = state.value == value
        return HLChoiceRow(LocalizedStringKey(kind.labelKey(for: value)), isSelected: isSelected, mode: .singleOpen) {
            guard !isSelected else { return }
            Task { await store.setValue(value, for: kind) }
        }
        .accessibilityIdentifier("anamnesis.choice.\(kind.rawValue).\(value.rawValue)")
    }

    // MARK: - Remove

    private var removeRow: some View {
        HLDeleteButton(
            "anamnesis.action.remove",
            form: .row,
            action: .confirmed(title: "settings.anamnesis.remove.confirm.title") {
                await store.removeCurrent(for: kind)
            }
        )
        .disabled(store.pendingKind != nil)
        .accessibilityIdentifier("anamnesis.remove.\(kind.rawValue)")
    }

    // MARK: - History

    /// Der Verlauf dieser Art, eingeklappt; erst da, wenn es einen gibt.
    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $showHistory) {
            AnamnesisFactHistoryList(revisions: history, kind: kind)
                .padding(.top, HLSpace.xs)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text("anamnesis.history.title")
                    .hlText(.groupHeader)
                if !history.isEmpty {
                    Text(verbatim: "\(history.count)")
                        .font(.hlCaption2.weight(.semibold))
                        .foregroundStyle(HLText.secondary)
                }
            }
        }
        .accessibilityIdentifier("anamnesis.history.\(kind.rawValue)")
    }
}
