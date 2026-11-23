import SwiftUI

/// **"Life circumstances".**
///
/// Reached from "About me", next to the anamnesis facts it extends, and only
/// when the server says it has the feature (`features.lifeCircumstances`,
/// v1.43). Six sections as one calm page: each section is a row of one card that
/// opens on a tap, saves on its own and keeps its AI switch under "Advanced". Below
/// them the screening hints the server derives, with their sources.
///
/// The old anamnesis screen stays as it was; smoking status and shift work
/// are the same facts on both screens, so an answer given on either shows on
/// the other.
///
/// The alcohol section is AUDIT-C (``AuditCSection``). Not here on purpose:
/// the take-over of free-text conditions and allergies, which the web leads.
struct LifeCircumstancesScreen: View {
    @Environment(\.appContainer) private var container
    @State private var store: LifeCircumstancesStore?

    /// The AI switch name of shift work (`extraAiSections`).
    static let shiftAISection = "SHIFT_SCHEDULE"

    var body: some View {
        content
            .navigationTitle("life.title")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("life.screen")
            .task {
                guard store == nil, let container else { return }
                let created = LifeCircumstancesStore(repo: LifeCircumstancesRepository(api: container.api))
                store = created
                await created.load()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            switch store.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                failedState(message, store: store)
            case let .disabled(reason):
                HLPage {
                    FeatureDisabledCard(variant: .hero, reason: reason)
                        .accessibilityIdentifier("life.disabled")
                }
            case .loaded:
                if let payload = store.payload {
                    page(payload, store: store)
                } else {
                    failedState(String(localized: "life.loadError"), store: store)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failedState(_ message: String, store: LifeCircumstancesStore) -> some View {
        HLEmptyState(
            icon: "wifi.exclamationmark",
            title: Text("life.loadError"),
            message: message == String(localized: "life.loadError") ? nil : Text(verbatim: message)
        ) {
            HLButton(HLControlWord.retry.key, systemImage: "arrow.clockwise", variant: .secondary) {
                Task { await store.load() }
            }
            .accessibilityIdentifier("life.retry")
        }
        .accessibilityIdentifier("life.loadFailed")
    }

    private func page(_ payload: LifeCircumstances, store: LifeCircumstancesStore) -> some View {
        HLPage {
            if store.isStale {
                notice(String(localized: "life.stale"), identifier: "life.stale") {
                    Task { await store.load() }
                }
            }
            if let message = store.notice {
                notice(message, identifier: "life.notice") { store.clearNotice() }
            }
            if payload.sections.isEmpty {
                HLEmptyState(icon: "person.text.rectangle", title: "life.empty")
                    .accessibilityIdentifier("life.empty")
            }
            if !payload.sections.isEmpty {
                // One card, one row per section, like every other list of
                // places to go on a settings page.
                HLCard(layout: .rows) {
                    ForEach(payload.sections) { section in
                        LifeSectionCard(section: section, payload: payload, store: store, canSave: !store.isStale)
                    }
                }
            }
            if !payload.derived.screeningHints.isEmpty {
                LifeScreeningHintsCard(hints: payload.derived.screeningHints)
            }
        }
        .refreshable { await store.load() }
    }

    /// One line about the page, with its one action (retry or dismiss).
    private func notice(_ text: String, identifier: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.hlFootnote)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HLSpace.sm)
            if identifier == "life.stale" {
                HLIconButton(systemImage: "arrow.clockwise", label: HLControlWord.retry.key, action: action)
            } else {
                HLDismissButton(label: "anamnesis.error.dismiss", action: action)
            }
        }
        .padding(.horizontal, HLSpace.md)
        .hlCardSurface()
        .accessibilityIdentifier(identifier)
    }
}

#Preview("LifeCircumstancesScreen") {
    NavigationStack { LifeCircumstancesScreen() }
}
