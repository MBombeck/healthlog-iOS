import Foundation

/// **Phase 18 / 18-02 — producing the chosen output, through the same stores as
/// before.**
///
/// Nothing here talks to the network. Each branch hands the values
/// `UnifiedSharingStore+Outputs` built to the store or service that already
/// owned that call — `ShareLinkStore`, `ExportStore`, `DoctorReportStore` and
/// its on-device fallback — so the consolidation is a change of *who asks the
/// questions*, not of who sends the request.
///
/// **One feedback shape for four outputs.** ``UnifiedSharingStore/outcome``,
/// ``UnifiedSharingStore/artifacts`` and ``UnifiedSharingStore/artifactSource``
/// are written by every branch. The four old cards each invented their own
/// working/ready/error rendering, which is part of why they read as four
/// products rather than four forms of one.
public extension UnifiedSharingStore {
    /// Everything the four branches need from the app's object graph, passed in
    /// rather than held, so the model stays a model.
    struct OutputContext {
        public let exportStore: ExportStore
        public let reportStore: DoctorReportStore
        public let localReportStore: LocalDoctorReportStore
        public let linkStore: ShareLinkStore
        public let snapshot: DoctorReportSpecBuilder.Snapshot
        public let locale: String
        public let isBackendReachable: Bool

        public init(
            exportStore: ExportStore,
            reportStore: DoctorReportStore,
            localReportStore: LocalDoctorReportStore,
            linkStore: ShareLinkStore,
            snapshot: DoctorReportSpecBuilder.Snapshot,
            locale: String,
            isBackendReachable: Bool
        ) {
            self.exportStore = exportStore
            self.reportStore = reportStore
            self.localReportStore = localReportStore
            self.linkStore = linkStore
            self.snapshot = snapshot
            self.locale = locale
            self.isBackendReachable = isBackendReachable
        }
    }

    /// Whether the current state could produce its chosen output at all. Drives
    /// the one action's disabled state; a builder that returns `nil` is the
    /// single source of that answer, so the button and the request agree.
    var canProduce: Bool {
        switch outputForm {
        case .link: shareLinkBody() != nil
        case .zip: packageRequest() != nil
        // Both of these have an on-device path that works with no server at
        // all, so refusing them on an unresolved scope would disable a control
        // that would have worked.
        case .pdf, .fhir: true
        }
    }

    /// Run the chosen output. Resets the shared feedback first so a second
    /// attempt never renders beside the first one's result.
    func produce(_ context: OutputContext) async {
        outcome = .working
        artifacts = []
        artifactSource = nil
        emptyBundleHasSelection = nil
        didMintLink = false

        switch outputForm {
        case .link: await produceLink(context)
        case .pdf: await producePDF(context)
        case .zip: await produceZIP(context)
        case .fhir: await produceFHIR(context)
        }
    }

    /// Drop the last result (the user changed a question, or dismissed it).
    func clearOutcome() {
        outcome = .idle
        artifacts = []
        artifactSource = nil
        emptyBundleHasSelection = nil
        didMintLink = false
        // The freshly-minted token itself belongs to `ShareLinkStore` and is
        // dropped there (`clearFreshToken()`); this model only stops pointing
        // at it.
    }

    // MARK: - Link

    private func produceLink(_ context: OutputContext) async {
        guard let body = shareLinkBody() else {
            outcome = .failed(String(localized: "sharing.unified.error.link"))
            return
        }
        if await context.linkStore.create(body) {
            didMintLink = true
            outcome = .produced
        } else {
            outcome = .failed(context.linkStore.error ?? String(localized: "sharing.unified.error.link"))
        }
    }

    // MARK: - PDF

    /// Prefer-server with the on-device fallback (FW5-C), exactly as the doctor
    /// report did: a server render that throws falls through to the local
    /// renderer so the output never dead-ends — except for the one refusal that
    /// is a contract mismatch rather than a hiccup, where the scope is rebuilt
    /// from a fresh capabilities read and the user retries.
    private func producePDF(_ context: OutputContext) async {
        if context.isBackendReachable, let arguments = pdfArguments(locale: context.locale) {
            await context.reportStore.generate(
                days: arguments.days,
                locale: arguments.locale,
                selection: arguments.selection,
                practiceName: arguments.practiceName
            )
            if let url = context.reportStore.pdfURL, context.reportStore.error == nil {
                artifacts = [url]
                artifactSource = .server
                outcome = .produced
                return
            }
            if let failure = context.reportStore.failure,
               await profile.handleExportFailure(failure)
            {
                outcome = .idle
                return
            }
            HLLog.api.info("Unified sharing: server PDF render failed — falling back to the on-device renderer")
        }
        await produceLocalPDF(context)
    }

    private func produceLocalPDF(_ context: OutputContext) async {
        context.localReportStore.periodDays = periodDays
        await context.localReportStore.generate(locale: context.locale == "en" ? .en : .de)
        guard context.localReportStore.pdfURL != nil, context.localReportStore.error == nil else {
            outcome = .failed(
                context.localReportStore.error?.userFacingDescription
                    ?? String(localized: "sharing.unified.error.pdf")
            )
            return
        }
        artifacts = context.localReportStore.shareItems
        artifactSource = .local
        outcome = .produced
    }

    // MARK: - ZIP

    private func produceZIP(_ context: OutputContext) async {
        guard let request = packageRequest() else {
            outcome = .failed(String(localized: "sharing.unified.error.zip"))
            return
        }
        do {
            artifacts = try await [context.exportStore.downloadHealthRecordPackage(request)]
            outcome = .produced
        } catch {
            if await profile.handleExportFailure(error) {
                outcome = .idle
                return
            }
            outcome = .failed(
                (error as? HLError)?.userFacingDescription
                    ?? String(localized: "sharing.unified.error.zip")
            )
        }
    }

    // MARK: - FHIR

    private func produceFHIR(_ context: OutputContext) async {
        // The one route whose request cannot carry the scope: publish the
        // visible selection as the stored profile first, so the bundle the
        // server assembles is the selection the user is looking at.
        await prepareFHIRScope()
        let generatedAt = now()
        switch await context.exportStore.assembleFHIR(
            periodDays: periodDays,
            snapshot: context.snapshot,
            generatedAt: generatedAt,
            isBackendReachable: context.isBackendReachable
        ) {
        case let .assembled(assembly):
            do {
                artifacts = try await [context.exportStore.persistFHIR(assembly.json, generatedAt: generatedAt)]
                artifactSource = assembly.source
                outcome = .produced
            } catch {
                outcome = .failed(String(localized: "sharing.unified.error.fhir"))
            }
        case let .empty(hasSavedSelection):
            emptyBundleHasSelection = hasSavedSelection
            outcome = .idle
        case .unavailable:
            outcome = .failed(String(localized: "sharing.unified.error.fhir"))
        }
    }
}
