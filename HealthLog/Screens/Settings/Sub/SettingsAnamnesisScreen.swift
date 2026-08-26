import SwiftUI

/// **CU-32 — Anamnese: Rauchen, Alkohol, Schichtarbeit.**
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
/// | nie erfasst | „Nie erfasst" + Hinweis, dass das etwas anderes ist als „keine" |
/// | erfasst, unlesbar | „Nicht lesbar" + Hinweis, dass etwas gespeichert ist |
/// | erfasst | die Beschriftung des Wertes **in dieser Art** |
///
/// „Trinke keinen Alkohol" ist eine Antwort. „Nie erfasst" ist keine. Bei einer
/// Anamnese ist das kein Detail — die eine Aussage trägt Information, die
/// andere nur Abwesenheit.
struct SettingsAnamnesisScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: AnamnesisFactsStore?

    var body: some View {
        Group {
            if backend.hasServer {
                connectedBody
            } else {
                List {
                    HLCloudDerivedPlaceholder(
                        variant: .inline,
                        surfaceName: String(localized: "anamnesis.title"),
                        onConnect: { authStore.beginServerPairing() }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("anamnesis.title")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("anamnesis.screen")
        .task {
            guard backend.hasServer, store == nil, let container else { return }
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
        HLEmptyState(icon: "wifi.exclamationmark", title: "anamnesis.loadFailed") {
            HLButton("Try again", icon: "arrow.clockwise", variant: .primary) {
                Task { await store.load() }
            }
        }
        .containerCentered()
        .accessibilityIdentifier("anamnesis.loadFailed")
    }

    private func page(store: AnamnesisFactsStore) -> some View {
        HLSettingsPage(title: "anamnesis.title") {
            if let writeError = store.writeError {
                writeErrorBanner(writeError, store: store)
            }
            ForEach(AnamnesisFactKind.allCases) { kind in
                AnamnesisFactCard(kind: kind, store: store)
            }
            Text("anamnesis.footer")
                .font(.hlFootnote)
                .foregroundStyle(HLText.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Der Schreibfehler steht oben und benennt den Sachverhalt. Bei den
    /// Fehlerbildern, deren Ausweg „neu laden" heisst, hat der Store das
    /// bereits getan — der Text sagt das auch.
    private func writeErrorBanner(_ message: String, store: AnamnesisFactsStore) -> some View {
        HStack(alignment: .top, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HLColor.statusBad)
            Text(message)
                .font(.hlFootnote)
                .foregroundStyle(HLText.primary)
            Spacer(minLength: HLSpace.sm)
            Button {
                store.clearWriteError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(HLText.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("anamnesis.error.dismiss")
        }
        .padding(HLSpace.md)
        .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card))
        .accessibilityIdentifier("anamnesis.writeError")
    }
}

#Preview("SettingsAnamnesisScreen") {
    NavigationStack { SettingsAnamnesisScreen() }
}
