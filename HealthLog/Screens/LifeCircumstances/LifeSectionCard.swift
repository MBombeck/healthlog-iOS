import SwiftUI

/// **LIFE (1.5.0)** — one section of the life circumstances as one card.
///
/// Closed, the card is a single row: the section's name and when it was last
/// answered or confirmed. Open, it holds the quiet yearly "still true?" (only
/// when the server says the answers are a year old), the questions, when the
/// answers hold from, the section's own save, and under the centred text link
/// "Advanced" the AI switch of the section. One card per section; nothing
/// inside it is a card.
struct LifeSectionCard: View {
    let section: LifeSection
    let payload: LifeCircumstances
    @Bindable var store: LifeCircumstancesStore
    let canSave: Bool
    @State private var isExpanded = false
    @State private var showsAdvanced = false
    @State private var validFrom = Date.now
    /// AUDIT-C form state of the alcohol section; lives as long as the screen.
    @State private var auditCModel = AuditCModel()

    var body: some View {
        HLSettingsCard {
            header
            if isExpanded {
                expandedBody
            }
        }
        .accessibilityIdentifier("life.section.\(section.key.rawValue)")
    }

    // MARK: - Header

    private var header: some View {
        Button {
            withHLAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: HLSpace.md) {
                HLSettingsIconChip(symbol: LifeCopy.symbol(section.key), tint: HLAccent.userBrandTint)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(verbatim: LifeCopy.title(section.key))
                        .font(.hlSubhead.weight(.semibold))
                        .foregroundStyle(HLText.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: statusLine)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: HLSpace.sm)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("life.section.\(section.key.rawValue).header")
    }

    private var statusLine: String {
        guard let confirmed = section.lastConfirmedAt else { return String(localized: "life.notAnswered") }
        return String(localized: "life.lastConfirmed \(HLDateFormat.date(confirmed, style: .long))")
    }

    // MARK: - Body

    @ViewBuilder
    private var expandedBody: some View {
        if section.reviewDue {
            reviewRow
        }
        if section.facts.contains(where: { $0.value == .unreadable }) {
            LifeDerivedLine(text: String(localized: "life.unreadable"), secondary: true)
        }
        if section.facts.contains(where: { $0.value == .unsupported }) {
            LifeDerivedLine(text: String(localized: "life.unsupported"), secondary: true)
        }
        LifeSectionFields(section: section, derived: payload.derived, draft: draftBinding, alcohol: alcohol)
            .disabled(!canSave || store.savingSection != nil)
        if !section.key.kinds.isEmpty {
            validityRows
            saveRow
        }
        advancedToggle
        if showsAdvanced {
            aiSwitches
        }
    }

    private var alcohol: AuditCSection? {
        guard section.key == .alcohol, let auditC = payload.auditC else { return nil }
        return AuditCSection(auditC: auditC, store: store, model: auditCModel)
    }

    private var draftBinding: Binding<LifeSectionDraft> {
        Binding(
            get: { store.draft(section.key) ?? LifeSectionDraft(section: section) },
            set: { store.drafts[section.key] = $0 }
        )
    }

    private var reviewRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            LifeDerivedLine(text: String(localized: "life.review.question"))
            Button {
                Task { await store.confirm(section.key) }
            } label: {
                Text("life.review.confirm")
                    .font(.hlSubhead.weight(.semibold))
                    .foregroundStyle(HLAccent.userBrandTint)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isUpdatingSettings || !canSave)
            .accessibilityIdentifier("life.section.\(section.key.rawValue).confirm")
        }
    }

    /// "Valid since" of the current answers; while the form holds changes,
    /// the day the new answers hold from (today unless the person picks an
    /// earlier day, never a later one).
    @ViewBuilder
    private var validityRows: some View {
        if let since = section.validSince {
            LifeAdaptiveRow(label: String(localized: "life.validSince")) {
                Text(verbatim: HLDateFormat.date(since, style: .long))
                    .font(.hlBody)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
        }
        if store.hasChanges(section.key) {
            DatePicker(
                selection: $validFrom,
                in: ...Date.now,
                displayedComponents: .date
            ) {
                LifeRowLabel(text: String(localized: "life.newValidFrom"))
            }
            .accessibilityIdentifier("life.section.\(section.key.rawValue).validFrom")
        }
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            if let error = store.sectionErrors[section.key] {
                HLFormErrorText(error)
            }
            HLButton(
                "life.save",
                variant: .secondary,
                isLoading: store.savingSection == section.key
            ) {
                Task {
                    let day = Calendar.current.isDateInToday(validFrom) ? nil : validFrom
                    if await store.save(section.key, validFrom: day) {
                        validFrom = .now
                    }
                }
            }
            .disabled(!canSave || !store.hasChanges(section.key) || store.savingSection != nil)
            .accessibilityIdentifier("life.section.\(section.key.rawValue).save")
        }
    }

    // MARK: - Advanced: AI switches

    private var advancedToggle: some View {
        Button {
            withHLAnimation(.easeInOut(duration: 0.25)) { showsAdvanced.toggle() }
        } label: {
            HStack(spacing: HLSpace.xs) {
                Text("Advanced")
                    .font(.hlSubhead.weight(.semibold))
                Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                    .font(.hlIcon(HLIconSize.sm))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsAdvanced ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("life.section.\(section.key.rawValue).advanced")
    }

    @ViewBuilder
    private var aiSwitches: some View {
        HLSettingsToggleRow(
            title: "life.ai.label",
            description: section.key == .work ? nil : "life.ai.hint",
            isOn: Binding(
                get: { section.aiIncluded },
                set: { on in Task { await store.setAI(section.aiSection, included: on) } }
            ),
            isBusy: store.isUpdatingSettings,
            isEnabled: canSave && !store.isUpdatingSettings,
            accessibilityID: "life.section.\(section.key.rawValue).ai"
        )
        if section.key == .work, let shift = payload.shiftScheduleAIIncluded {
            HLSettingsToggleRow(
                title: "life.ai.shiftLabel",
                description: "life.ai.hint",
                isOn: Binding(
                    get: { shift },
                    set: { on in Task { await store.setAI(LifeCircumstancesScreen.shiftAISection, included: on) } }
                ),
                isBusy: store.isUpdatingSettings,
                isEnabled: canSave && !store.isUpdatingSettings,
                accessibilityID: "life.section.work.aiShift"
            )
        }
    }
}
