import SwiftUI
import UniformTypeIdentifiers

/// `Settings → Export → Import data` — the cold-start CSV import surface (server
/// v1.17.1). Pick a measurements CSV, see a **dry-run preview** (projected
/// insert / update / skip counts, no writes), then commit the real import on
/// confirmation. Mirrors the web import's trust-first "preview before you write"
/// flow — a bulk restore should never surprise the user.
///
/// Server-only: gated on `BackendAvailability.hasServer` (standalone has no
/// import route). Orchestration lives in ``ImportStore``; this view owns only
/// the picker flag and renders the store's published phase.
struct ImportDataScreen: View {
    @Environment(BackendAvailability.self) private var backend
    @Environment(AuthStore.self) private var authStore
    @Environment(\.appContainer) private var container

    @State private var store: ImportStore?
    @State private var isPickerPresented = false

    private var phase: ImportStore.Phase {
        store?.phase ?? .idle
    }

    var body: some View {
        content
            .navigationTitle("import.title")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePick(result)
            }
    }

    @ViewBuilder private var content: some View {
        if backend.hasServer {
            HLSettingsPage(title: "import.title") {
                formatCard
                actionCard
            }
        } else {
            ScrollView {
                HLCloudDerivedPlaceholder(
                    variant: .hero,
                    surfaceName: String(localized: "import.placeholder.surface"),
                    onConnect: { authStore.beginServerPairing() }
                )
                .padding(HLSpace.lg)
            }
            .background(HLColor.background)
        }
    }

    private var formatCard: some View {
        HLSettingsCard(
            icon: "tablecells",
            title: "import.format.title"
        ) {
            // Audit-Gruppe 15 — der Untertitel fragte „Welche Spalten deine
            // Datei enthalten sollte." und der Karteninhalt direkt darunter
            // antwortete. Die Antwort ist die Heimat.
            Text("import.format.footer")
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionCard: some View {
        HLSettingsCard(
            icon: "square.and.arrow.down.on.square",
            title: "import.action.title",
            subtitle: "import.action.subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                switch phase {
                case .idle, .failed:
                    pickButton
                    if case let .failed(reason) = phase {
                        messageRow(icon: "exclamationmark.triangle.fill", text: reason, tone: .bad)
                    }
                case .previewing:
                    progressRow(label: String(localized: "import.previewing"))
                case let .previewed(result):
                    previewSummary(result)
                    commitButtons
                case .importing:
                    progressRow(label: String(localized: "import.importing"))
                case let .done(result):
                    doneSummary(result)
                    importAnotherButton
                }
            }
        }
    }

    private var pickButton: some View {
        HLButton(
            String(localized: "import.pick.button"),
            icon: "doc.badge.plus",
            // R9 — die Commit-Aktion dieses Flows; `.primary` und
            // `import.commit.button` rendern nie gleichzeitig (Phasen).
            variant: .primary
        ) {
            isPickerPresented = true
        }
        .disabled(container?.api == nil)
        .accessibilityIdentifier("import.pick.button")
    }

    private var commitButtons: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HLButton(String(localized: "import.commit.button"), icon: "square.and.arrow.down", variant: .primary) {
                Task { await store?.commit() }
            }
            .accessibilityIdentifier("import.commit.button")

            HLButton(String(localized: "import.cancel.button"), variant: .secondary) {
                store?.reset()
            }
            .accessibilityIdentifier("import.cancel.button")
        }
    }

    private var importAnotherButton: some View {
        HLButton(String(localized: "import.another.button"), icon: "arrow.clockwise", variant: .secondary) {
            store?.reset()
        }
        .accessibilityIdentifier("import.another.button")
    }

    // MARK: - Summaries

    private func previewSummary(_ result: CSVImportResult) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            Text("import.preview.heading")
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
            countRow(label: String(localized: "import.count.total"), value: result.total)
            countRow(label: String(localized: "import.count.willWrite"), value: result.writeCount)
            countRow(label: String(localized: "import.count.skipped"), value: result.skipped)
            // Audit-Gruppe 14 — „In der Vorschau wird nichts geschrieben.
            // Bestätige, um den Import auszuführen." stand hier direkt über den
            // Knöpfen „Import ausführen" / „Abbrechen", die genau diese Wahl
            // schon anbieten, und der Karten-Untertitel sagt es ein drittes
            // Mal. Heimat ist der Karten-Untertitel (`import.action.subtitle`),
            // wo die Aktion beginnt.
        }
    }

    private func doneSummary(_ result: CSVImportResult) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.md) {
            messageRow(
                icon: "checkmark.circle.fill",
                text: String(localized: "import.done.heading"),
                tone: .ok
            )
            countRow(label: String(localized: "import.count.inserted"), value: result.inserted)
            countRow(label: String(localized: "import.count.updated"), value: result.updated)
            countRow(label: String(localized: "import.count.skipped"), value: result.skipped)
        }
    }

    private func countRow(label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
            Spacer()
            Text(value.formatted(.number))
                .font(.hlSubhead.weight(.semibold))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
        }
    }

    private enum Tone { case ok, bad }

    private func messageRow(icon: String, text: String, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: HLSpace.md) {
            Image(systemName: icon)
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(tone == .ok ? HLColor.statusOK : HLColor.statusBad)
                .accessibilityHidden(true)
            Text(text)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressRow(label: String) -> some View {
        HStack(spacing: HLSpace.md) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
        }
    }

    // MARK: - Picker

    private var allowedContentTypes: [UTType] {
        [.commaSeparatedText, .plainText]
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let active = store ?? container?.makeImportStore()
            store = active
            Task { await active?.preview(fileURL: url) }
        case .failure:
            // The user cancelled or the picker failed — stay idle, no error noise.
            break
        }
    }
}
