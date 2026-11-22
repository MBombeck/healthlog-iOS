import SwiftUI

/// **Anamnese: Rauchen, Alkohol, Schichtarbeit.**
///
/// Die Fläche zeigt drei effektiv-datierte Angaben. Ihr Zweck ist **nicht** nur
/// der heutige Stand, sondern seit wann er gilt und was vorher galt — deshalb
/// trägt jede Karte eine Gültigkeitszeile, ein Provenienz-Abzeichen
/// (Erstangabe gegen Korrektur) und ihren eigenen Verlauf.
///
/// **Drei Zustände, nicht zwei.** Ein leeres Feld wird hier nirgends als
/// „keine" gerendert:
///
/// | Zustand | Anzeige |
/// |---|---|
/// | nie erfasst | „Nie erfasst"; dass das etwas anderes ist als „keine", sagt das (i) |
/// | erfasst, unlesbar | „Nicht lesbar" + Hinweis, dass etwas gespeichert ist |
/// | erfasst | die Beschriftung des Wertes **in dieser Art** |
///
/// „Trinke keinen Alkohol" ist eine Antwort. „Nie erfasst" ist keine. Bei einer
/// Anamnese ist das kein Detail — die eine Aussage trägt Information, die
/// andere nur Abwesenheit.
struct SettingsAnamnesisScreen: View {
    @Environment(\.appContainer) private var container

    @State private var store: AnamnesisFactsStore?

    var body: some View {
        connectedBody
            .navigationTitle("anamnesis.title")
            .navigationBarTitleDisplayMode(.inline)
            // The screen's one (i): where these answers are kept and
            // what "never recorded" means, once instead of under each card and
            // below the last one.
            .hlPageActions([.info(Self.info, identifier: "anamnesis.info")])
            .accessibilityIdentifier("anamnesis.screen")
            .task {
                guard store == nil, let container else { return }
                let created = AnamnesisFactsStore(repo: AnamnesisRepository(api: container.api))
                store = created
                await created.load()
            }
    }

    @ViewBuilder
    private var connectedBody: some View {
        if let store {
            if store.didLoad {
                if store.loadFailed, store.isEmpty {
                    loadFailedState(store: store)
                } else {
                    page(store: store)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadFailedState(store: AnamnesisFactsStore) -> some View {
        HLErrorState("anamnesis.loadFailed") {
            await store.load()
        }
        .accessibilityIdentifier("anamnesis.loadFailed")
    }

    private func page(store: AnamnesisFactsStore) -> some View {
        HLPage {
            if let writeError = store.writeError {
                writeErrorBanner(writeError, store: store)
            }
            ForEach(AnamnesisFactKind.allCases) { kind in
                AnamnesisFactCard(kind: kind, store: store)
            }
        }
    }

    static var info: HLInfoContent {
        HLInfoContent(
            title: String(localized: "anamnesis.title"),
            identifier: "anamnesis.info.sheet",
            about: String(localized: "anamnesis.footer"),
            sections: [
                HLInfoContent.Section(
                    title: String(localized: "anamnesis.state.neverRecorded"),
                    paragraphs: [String(localized: "anamnesis.state.neverRecorded.hint")]
                )
            ]
        )
    }

    /// Der Schreibfehler steht oben und benennt den Sachverhalt. Bei den
    /// Fehlerbildern, deren Ausweg „neu laden" heisst, hat der Store das
    /// bereits getan — der Text sagt das auch.
    private func writeErrorBanner(_ message: String, store: AnamnesisFactsStore) -> some View {
        HLCard {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HLColor.statusBad)
                Text(message)
                    .font(.hlFootnote)
                    .foregroundStyle(HLText.primary)
                Spacer(minLength: HLSpace.sm)
                HLDismissButton(label: "anamnesis.error.dismiss") {
                    store.clearWriteError()
                }
            }
        }
        .accessibilityIdentifier("anamnesis.writeError")
    }
}

#Preview("SettingsAnamnesisScreen") {
    NavigationStack { SettingsAnamnesisScreen() }
}
