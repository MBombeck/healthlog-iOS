import Foundation

/// **Phase 18 / 18-02 — the four outputs, from one state.**
///
/// The unified surface consolidates the *questions*, never the *contracts*.
/// This file is where that distinction is kept: it turns the one model state
/// into exactly the request values the four existing call sites already took,
/// and hands them to the same stores and services that sent them before. No
/// route is new, no request shape moves, and `SharingWireFixtureTests`'
/// committed fixtures — captured from the untouched implementations in
/// `e9bfe8c5`, before anything was rewired — are what holds that to be true.
///
/// **Every builder returns `nil` rather than a guess.** A request whose scope
/// nobody could state, a link with no valid expiry, a label the server would
/// refuse: each is a reason not to fire, not a reason to substitute a default.
/// `nil` is what the surface renders its disabled action from.
public extension UnifiedSharingStore {
    /// Everything `DoctorReportStore.generate(days:locale:selection:practiceName:)`
    /// takes. A struct rather than four loose values because the PDF path is the
    /// one output whose request body is built inside its service, so the model's
    /// contribution is precisely this argument list.
    struct PDFArguments: Equatable, Sendable {
        public let days: Int
        public let locale: String
        public let selection: ReportSelection
        public let practiceName: String?
    }

    /// Server bound on a share-link label (`createShareLinkSchema`).
    static var linkLabelLength: ClosedRange<Int> {
        1 ... 120
    }

    // MARK: - PDF

    /// The arguments the server-rendered report takes, or `nil` when the form
    /// is not the PDF or no scope is resolvable yet.
    ///
    /// `practiceName` is `nil` for a blank field. That is the user's answer, and
    /// the request omits the key entirely rather than sending `null` — the
    /// schema is `.strict()`, and a stray key is a 422.
    func pdfArguments(locale: String) -> PDFArguments? {
        guard outputForm == .pdf, let selection = resolvedSelection else { return nil }
        let trimmed = practiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PDFArguments(
            days: periodDays,
            locale: locale,
            selection: selection,
            practiceName: trimmed.isEmpty ? nil : trimmed
        )
    }

    // MARK: - ZIP

    /// The health-record package request, or `nil` when the form is not the ZIP
    /// or no scope is resolvable yet.
    ///
    /// Same route as the PDF, differing in `format` — which is the whole reason
    /// these two stopped being separate cards. `locale` and `practiceName` are
    /// absent because the package call never sent them.
    func packageRequest() -> HealthRecordExportRequest? {
        guard outputForm == .zip, let selection = resolvedSelection else { return nil }
        return HealthRecordExportRequest(
            format: .package,
            selection: selection,
            range: HealthRecordExportRequest.Range(days: periodDays),
            includeCharts: includeCharts
        )
    }

    // MARK: - Link

    /// The share-link create body, or `nil` when anything the server would
    /// refuse is still true: wrong form, unresolved scope, a label outside
    /// 1…120, an expiry that is absent / past / more than 90 days out, or a leaf
    /// this route forbids.
    ///
    /// **The period becomes `rangeStart`, and `rangeEnd` stays `nil`.** The old
    /// sheet asked for a from-date plus a rolling-window switch; the unified
    /// surface asks for a look-back window, which is the same question with one
    /// fewer control. A rolling window always ends today, so `nil` is what that
    /// answer has always looked like on the wire.
    func shareLinkBody() -> CreateShareLinkBody? {
        guard outputForm == .link, let selection = resolvedSelection, let expiresAt else { return nil }
        let trimmed = linkLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.linkLabelLength.contains(trimmed.count),
              validateExpiry().isEmpty,
              ShareLinkSelectionPolicy.forbiddenLeaves(in: selection).isEmpty else { return nil }
        let reference = now()
        let start = calendar.date(byAdding: .day, value: -periodDays, to: reference) ?? reference
        return CreateShareLinkBody(
            label: trimmed,
            rangeStart: ShareLinkDateFormat.string(from: start),
            rangeEnd: nil,
            expiresAt: ShareLinkDateFormat.string(from: expiresAt),
            selection: selection
        )
    }

    // MARK: - FHIR

    /// Publish the visible selection as the scope the server will apply to
    /// `GET /api/fhir/Patient/$everything`, and report whether it landed.
    ///
    /// **This is the end of the silent inheritance.** The `$everything` request
    /// carries no selection — the server scopes the Bundle to the owner's stored
    /// report profile — so FHIR was the one export whose content was decided by
    /// a profile the user never saw. It is now decided by the same visible
    /// choice as the other three, and the only way to say that on this route is
    /// to write the profile first. The fetch itself is untouched: same path,
    /// same query, same header, byte for byte.
    @discardableResult
    func prepareFHIRScope() async -> Bool {
        guard outputForm == .fhir, isReady else { return false }
        await save()
        return profile.saveError == nil
    }
}
