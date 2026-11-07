import SwiftUI

/// #141 — the page behind a related row. It resolves the record from the
/// list the app already holds (instant), else reads that one record, then shows
/// the same detail screen its own list opens. While reading it shows a spinner;
/// a record that is gone, a module that is off and a failed read each get their
/// own terminal state, the failure with "Retry".
struct RelatedRecordDestination: View {
    let link: RelatedLink

    @Environment(\.appContainer) private var container
    @State private var phase: RelatedRecordPhase = .loading
    @State private var attempt = 0

    var body: some View {
        content
            .task(id: attempt) { await resolve() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            placeholder { ProgressView() }
        case let .lab(row):
            if let store = container?.labsStore {
                LabResultDetailScreen(store: store, resultID: row.id, summary: row)
            }
        case let .document(document):
            if let store = container?.documentsStore {
                DocumentDetailScreen(store: store, documentId: document.id, initialDocument: document)
            }
        case let .episode(episode):
            if let store = container?.illnessStore {
                IllnessEpisodeDetailScreen(store: store, episode: episode)
            }
        case let .medication(medication):
            if let container {
                MedicationDetailScreen(
                    medication: medication,
                    repo: container.medicationsRepo,
                    glp1LocalRepo: container.glp1LocalRepo,
                    therapyLogRepo: container.syncModeStore.isPaired ? container.medicationTherapyLogRepo : nil,
                    profileTimeZoneProvider: container.medicationsStore.profileTimeZoneProvider
                )
            }
        case let .disabled(reason):
            placeholder { FeatureDisabledCard(variant: .hero, reason: reason) }
        case .notFound:
            placeholder {
                HLEmptyState(icon: "questionmark.folder", title: "related.open.notFound.title")
            }
            .accessibilityIdentifier("related.open.notFound")
        case .failed:
            placeholder {
                HLEmptyState(icon: "exclamationmark.triangle", title: "related.open.failed.title") {
                    HLButton("Retry", variant: .secondary) {
                        attempt += 1
                    }
                    .accessibilityIdentifier("related.open.retry")
                }
            }
            .accessibilityIdentifier("related.open.failed")
        }
    }

    private func placeholder(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .padding(HLSpace.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .hlScreenBackground()
            .navigationTitle(Text(verbatim: link.label))
            .navigationBarTitleDisplayMode(.inline)
    }

    private func resolve() async {
        guard let container else { return }
        if attempt > 0 { phase = .loading }
        do {
            phase = try await RelatedRecordResolver.resolve(link, in: container)
        } catch {
            let gate = container.moduleGate
            phase = RelatedRecordPhase.after(error, kind: link.kind) { gate.offReason($0) }
        }
    }
}

/// What the destination shows.
enum RelatedRecordPhase {
    case loading
    case lab(LabResultDTO)
    case document(InboundDocument)
    case episode(IllnessEpisodeDTO)
    case medication(Medication)
    case disabled(String?)
    case notFound
    case failed

    /// A refused read is the module (or the grant) being off, a 404 is a record
    /// that is gone, anything else can be tried again.
    static func after(
        _ error: Error,
        kind: RelatedLink.Kind,
        offReason: (ModuleKey) -> String?
    ) -> RelatedRecordPhase {
        switch error as? HLError {
        case .moduleDisabled:
            .disabled(kind.moduleKey.flatMap(offReason))
        case let .server(status, _, _) where status == 403:
            .disabled(kind.moduleKey.flatMap(offReason))
        case let .server(status, _, _) where status == 404:
            .notFound
        default:
            .failed
        }
    }
}

extension RelatedLink.Kind {
    /// The module a kind's page belongs to.
    var moduleKey: ModuleKey? {
        switch self {
        case .labResult: .labs
        case .document: .inboundDocuments
        case .conditionEpisode: .illness
        case .medication: .medications
        case .encounter, .vaccination: nil
        }
    }
}

/// Finds the record a related row points at: first in the list the app holds,
/// else by reading that one record.
@MainActor
enum RelatedRecordResolver {
    static func resolve(_ link: RelatedLink, in container: AppContainer) async throws -> RelatedRecordPhase {
        let id = link.recordID
        switch link.kind {
        case .labResult:
            if let row = container.labsStore.labs.first(where: { $0.id == id }) { return .lab(row) }
            return try await .lab(LabResultDTO(detail: container.labsStore.fetchDetail(id: id)))
        case .document:
            if let row = container.documentsStore.documents.first(where: { $0.id == id }) { return .document(row) }
            return try await .document(container.documentsStore.detail(id: id).document)
        case .conditionEpisode:
            if let row = container.illnessStore.episodes.first(where: { $0.id == id }) { return .episode(row) }
            return try await .episode(container.illnessRepo.episode(id: id))
        case .medication:
            if let row = container.medicationsStore.medications.first(where: { $0.id == id }) { return .medication(row) }
            return try await .medication(container.medicationsRepo.medication(id: id))
        case .encounter, .vaccination:
            return .notFound
        }
    }
}

extension LabResultDTO {
    /// The list-row shape of a single read, for a lab result opened from a
    /// related row before the lab list was loaded.
    init(detail: LabResultDetailDTO) {
        self.init(
            id: detail.id,
            biomarkerId: detail.biomarkerId,
            panel: detail.panel,
            analyte: detail.analyte,
            value: detail.value,
            valueText: detail.valueText,
            unit: detail.unit,
            referenceLow: detail.referenceLow,
            referenceHigh: detail.referenceHigh,
            takenAt: detail.takenAt,
            source: detail.source,
            hasNote: !(detail.note?.isEmpty ?? true),
            rangeStatus: detail.rangeStatus,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            converted: detail.converted,
            sourceValue: detail.sourceValue,
            sourceUnit: detail.sourceUnit,
            printedReferenceText: detail.printedReferenceText
        )
    }
}
