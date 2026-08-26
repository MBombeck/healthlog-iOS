import Foundation

// MARK: - ExportStore factory (audit v0162 H2)

public extension AppContainer {
    /// Builds an ``ExportStore`` wired to the container's API client, outbox, and
    /// module gate. Called on demand by the PHI-export / import screens (mirrors
    /// ``makeBYOKeyEntryModel()``): the store owns the repository/service calls +
    /// FHIR/export artifact assembly the views previously did inline.
    func makeExportStore() -> ExportStore {
        ExportStore(api: api, outbox: outbox, moduleGate: moduleGate)
    }

    /// Builds a ``ReportSelectionStore`` (CU-11) wired to the live capabilities
    /// route and the saved-profile route. Called on demand by the two surfaces
    /// that post a `selection` — the doctor-report PDF and the health-record
    /// package — so both read the same live leaf vocabulary and the same saved
    /// profile instead of keeping two ideas of the user's scope.
    @MainActor
    func makeReportSelectionStore() -> ReportSelectionStore {
        ReportSelectionStore(
            capabilities: ServerCapabilitiesRepository(api: api),
            profiles: ReportSelectionRepository(api: api)
        )
    }

    /// **Phase 18 / E1.1** — builds the unified sharing surface's model.
    ///
    /// It wraps the SAME ``ReportSelectionStore`` the old export surfaces used,
    /// which is the point: the scope, the period and the presentation flags are
    /// the account's one saved report profile, not a fifth private copy. The
    /// caller passes the output form its entry point implied.
    @MainActor
    func makeUnifiedSharingStore(
        form: UnifiedSharingStore.OutputForm = .link
    ) -> UnifiedSharingStore {
        UnifiedSharingStore(profile: makeReportSelectionStore(), form: form)
    }

    /// **CU-35 (2)** — builds a ``ReportPracticeNameStore`` for the health
    /// report's optional practice-name field. On demand (same shape as
    /// ``makeReportSelectionStore()``) so the prefill's "typed beats suggested"
    /// state lives exactly as long as the screen that owns the field.
    @MainActor
    func makeReportPracticeNameStore() -> ReportPracticeNameStore {
        ReportPracticeNameStore(repo: SettingsRepository(api: api))
    }

    /// Builds an ``ImportStore`` wired to the container's API client. Called on
    /// demand by ``ImportDataScreen`` (mirrors ``makeExportStore()``): the store
    /// owns the CSV file-read + dry-run/commit orchestration through
    /// ``ImportService`` so the view stays thin.
    @MainActor
    func makeImportStore() -> ImportStore {
        ImportStore(service: ImportService(api: api))
    }
}
