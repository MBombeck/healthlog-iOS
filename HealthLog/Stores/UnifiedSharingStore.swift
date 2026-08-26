import Foundation
import Observation

/// **Phase 18 / E1.1 — the one sharing surface's model.**
///
/// The walkthrough's D2 finding was that "es ist nicht durchgängig klar, was
/// womit geteilt wird": four cards (Gesundheitsakte ZIP, Arzt-Link,
/// Gesundheitsbericht PDF, FHIR-Export) each asked their own overlapping
/// version of *what* and *for how long*, and answered them differently. The
/// research behind Phase 18 showed the overlap was almost total — ZIP and PDF
/// are the SAME endpoint differing only in `format`, three of four already
/// spoke the `share.leaves` vocabulary and the stored report-selection profile,
/// and the FHIR export inherited that profile with no UI at all.
///
/// This model asks the two questions ONCE — ``Question/what`` (the single
/// ``ReportSelection``) and ``Question/period`` — and puts the output form last
/// (``Question/form``). The four outputs are siblings, not four flows.
///
/// **It owns no state of its own where the server already has some.** The
/// scope, the period and the presentation flags ARE
/// ``ReportSelectionStore`` — the saved report profile behind
/// `GET | PUT /api/auth/me/report-selection`. That is deliberate: it is the
/// piece of server state the four old surfaces already shared without saying
/// so, and the FHIR export consumed invisibly. Reading it through one model is
/// what turns the silent inheritance into a visible choice.
@MainActor
@Observable
public final class UnifiedSharingStore {
    /// The complete question set of the sharing surface, in the order it asks.
    /// Three, and the form is deliberately last (E1.1).
    public enum Question: String, CaseIterable, Sendable, Hashable {
        /// Which leaves ride — the single ``ReportSelection``.
        case what
        /// Which look-back window the content covers.
        case period
        /// Link / PDF / ZIP / FHIR — chosen after the content is settled.
        case form
    }

    /// The four outputs, as siblings of one flow.
    public enum OutputForm: String, CaseIterable, Sendable, Hashable, Identifiable {
        case link
        case pdf
        case zip
        case fhir

        public var id: String {
            rawValue
        }

        /// How this form rides in the saved profile's `format` field, or `nil`
        /// when it has no representation there. The stored vocabulary is the
        /// server's closed `z.enum(["pdf","fhir","package"])`; a share link is
        /// not an export format, so choosing it leaves the stored `format`
        /// alone rather than inventing a fourth value the route would refuse.
        var profileFormat: ReportFormat? {
            switch self {
            case .pdf: .pdf
            case .zip: .package
            case .fhir: .fhir
            case .link: nil
            }
        }
    }

    /// The panel's readiness. Aliased rather than re-declared: this store has
    /// no phase of its own, it reports the profile's.
    public typealias Phase = ReportSelectionStore.Phase
    public typealias Unavailability = ReportSelectionStore.Unavailability

    /// Everything the server would refuse about a link expiry, surfaced
    /// pre-flight. Exactly the three rules `CreateShareLinkSheet` enforced:
    /// REQUIRED, in the future, at most 90 days ahead.
    public enum ExpiryIssue: Sendable, Equatable, Hashable {
        case missing
        case notInFuture
        case tooFarAhead(maxDays: Int)
    }

    // MARK: - Vocabulary of the surface itself

    /// What / period / form — and the form LAST. D2's complaint was four
    /// surfaces asking overlapping questions in different orders; this array is
    /// the single answer, and a test holds it to that shape.
    public static let questionOrder: [Question] = [.what, .period, .form]

    /// The unified period vocabulary: the **intersection** the server accepts
    /// on every route this surface drives. Three of the four old surfaces
    /// offered 30/60/90/180/365 and one offered 30/90/180/365, so 60 is absent
    /// — a window one output could not honour is not a window this surface may
    /// offer.
    public static let periodOptions: [Int] = [30, 90, 180, 365]

    /// Server cap on a share link's life (`createShareLinkSchema`).
    public static let maxExpiryDays = 90

    /// Default number of days a freshly-offered link lives. Matches what the
    /// create sheet offered, so a user who accepts the default mints the same
    /// link they would have minted before the consolidation.
    public static let defaultExpiryDays = 30

    /// **The default selection is EMPTY, and it stays empty — decision E1.2,
    /// answered by the operator on 2026-08-22.**
    ///
    /// Read this before changing it. The operator's walkthrough sentence says
    /// a freshly created link "sollte standardmäßig alles enthalten sein", and
    /// a later reader who finds that transcript will be tempted to make this
    /// the full vocabulary. It was already considered, in front of him, and
    /// decided the other way.
    ///
    /// **Why.** In the v2 grammar membership is inclusion and absence is
    /// exclusion (see ``ReportSelection``). An empty selection therefore means
    /// *no health data* — the documents-only link. Seeding the default with
    /// everything would not be a convenience; it would invert the meaning of
    /// the one shape the server introduced to stop a caller who sent nothing
    /// from receiving the entire record. Shown that consequence, the operator
    /// chose the safer reading of his own request: **the default stays empty,
    /// and an explicit „Alles auswählen" control makes the whole record one
    /// tap.** Selecting everything is an act, never a state somebody forgot to
    /// opt out of.
    ///
    /// The rationale lives in four places on purpose — here, in
    /// `.planning/active/v1-readiness/DECISIONS.md` (E1.2), in the phase's
    /// `18-CONTEXT.md`, and in the failure message of
    /// `UnifiedSharingModelTests.emptyDefaultWithSelectAll`, which fails loudly
    /// and names DECISIONS.md if this ever becomes non-empty. The walkthrough
    /// is the anamnesis; DECISIONS.md is the prescription.
    public static let defaultSelection: ReportSelection = .empty

    // MARK: - State

    public private(set) var outputForm: OutputForm

    /// When the link stops working. **Not** the period — see
    /// ``validateExpiry()``. Link-only; the three export forms ignore it.
    public var expiresAt: Date?

    /// The label a share link is recognised by later. Link-only; 1…120 chars
    /// trimmed, exactly as `createShareLinkSchema` requires.
    public var linkLabel: String = ""

    /// The practice a PDF report is addressed to. PDF-only, optional; a blank
    /// field is the user's answer and rides as an omitted key, never as `null`.
    public var practiceName: String = ""

    /// Leaf ids dropped by the most recent ``setOutputForm(_:)`` because the
    /// newly chosen form may not carry them. Empty on every other path — a
    /// narrowing the user did not ask for has to be visible.
    public private(set) var droppedForForm: [String] = []

    // MARK: - Output feedback — ONE shape for all four

    /// Where the current attempt stands. Deliberately one enum for every
    /// output: the four old cards each had their own idea of "working" and
    /// "failed", which is how a user could tell them apart by how they behaved
    /// rather than by what they produce.
    public enum Outcome: Equatable, Sendable {
        case idle
        case working
        case produced
        /// Already-localized text. Never a wire code.
        case failed(String)
    }

    public internal(set) var outcome: Outcome = .idle

    /// Files the result card hands to a share sheet — the PDF, the ZIP, the
    /// FHIR bundle (and, on the on-device report path, the co-emitted bundle).
    public internal(set) var artifacts: [URL] = []

    /// Which emitter produced the last PDF / FHIR artifact, so the result can
    /// say whether it is the server's render or the on-device fallback.
    public internal(set) var artifactSource: FHIRExportSource?

    /// Set when the server's scoped FHIR bundle came back with zero entries
    /// (CU-13). The payload is whether a report selection is saved at all —
    /// an empty bundle is a state to name, never a file to hand over.
    public internal(set) var emptyBundleHasSelection: Bool?

    /// True once a link has just been minted, so the surface reveals the
    /// one-time token panel in place.
    public internal(set) var didMintLink = false

    /// The report-selection profile — the ONE piece of server state the four
    /// old surfaces already shared without admitting it.
    public let profile: ReportSelectionStore

    let now: () -> Date

    /// Day arithmetic for the expiry default, the 90-day cap and the link's
    /// `rangeStart`. `Calendar.current` in production — that is what the create
    /// sheet used and the consolidation must not change it. Injectable so a
    /// fixture can pin a zone: adding days across a DST boundary is not a
    /// constant number of seconds, and a wire fixture has to mean the same
    /// thing on every machine that verifies it.
    let calendar: Calendar

    public init(
        profile: ReportSelectionStore,
        form: OutputForm = .link,
        now: @escaping () -> Date = { .now },
        calendar: Calendar = .current
    ) {
        self.profile = profile
        outputForm = form
        self.now = now
        self.calendar = calendar
        expiresAt = calendar.date(
            byAdding: .day,
            value: Self.defaultExpiryDays,
            to: now()
        )
    }

    // MARK: - Derived (delegating to the profile — never a second copy)

    public var phase: Phase {
        profile.phase
    }

    public var isReady: Bool {
        profile.isReady
    }

    public var vocabulary: [String] {
        profile.vocabulary
    }

    public var chosen: Set<String> {
        profile.chosen
    }

    /// The look-back window the content covers. This IS the saved profile's
    /// `rangeDays`; there is no second field, which is what keeps "what the
    /// doctor sees" from drifting between the four outputs.
    public var periodDays: Int {
        get { profile.rangeDays }
        set { profile.rangeDays = newValue }
    }

    public var includeCharts: Bool {
        get { profile.includeCharts }
        set { profile.includeCharts = newValue }
    }

    /// Leaf ids the **current output form** may carry, in the server's
    /// catalogue order.
    ///
    /// One documented subtraction, and only one: `POST /api/share-links`
    /// refuses `INSURANCE` (`ShareLinkSelectionPolicy`), so a link never offers
    /// it. The export route accepts it, so the three export forms do. The
    /// vocabulary itself is never authored here — it is `share.leaves`,
    /// verbatim.
    public var offeredLeaves: [String] {
        outputForm == .link
            ? ShareLinkSelectionPolicy.offeredLeaves(from: profile.vocabulary)
            : profile.vocabulary
    }

    /// The scope as the wire value every output takes.
    public var currentSelection: ReportSelection {
        profile.currentSelection
    }

    /// The scope to send, or `nil` when the panel has nothing honest to offer.
    /// An empty *selection* is an answer; `nil` is the absence of one.
    public var resolvedSelection: ReportSelection? {
        profile.resolvedSelection
    }

    /// True when the user has chosen nothing at all — the documents-only case
    /// the link copy has to state before anyone shares it.
    public var isDocumentsOnly: Bool {
        profile.chosen.isEmpty
    }

    // MARK: - Editing

    /// Switch the output form, narrowing the scope to what the new form may
    /// carry. Narrowing only ever removes, and what it removed is published in
    /// ``droppedForForm`` so the surface can say it out loud.
    public func setOutputForm(_ form: OutputForm) {
        outputForm = form
        let allowed = Set(offeredLeaves)
        let dropped = profile.chosen.subtracting(allowed)
        droppedForForm = dropped.sorted()
        if !dropped.isEmpty {
            profile.choose(profile.chosen.intersection(allowed))
        }
    }

    public func toggle(_ leaf: String) {
        droppedForForm = []
        profile.toggle(leaf)
    }

    public func isChosen(_ leaf: String) -> Bool {
        profile.isChosen(leaf)
    }

    /// **E1.2's explicit act.** Admit every leaf the current form may carry.
    ///
    /// This is the control the operator chose *instead of* a full default, and
    /// the difference is the whole point: the user performs it, sees the count
    /// change, and can undo it with ``clearSelection()``. The sensitive tier
    /// the server fences still exists — the surface says what a full selection
    /// contains next to this control, because a one-tap convenience that hides
    /// what it switched on would be the old defect with a button on it.
    public func selectAll() {
        droppedForForm = []
        profile.choose(offeredLeaves)
    }

    /// The inverse. Legal, and means *no health data* — never "undecided".
    public func clearSelection() {
        droppedForForm = []
        profile.selectNone()
    }

    // MARK: - Round-trip

    /// Read the live leaf vocabulary and the saved profile. One read for the
    /// whole surface: all four outputs run from what lands here.
    public func load() async {
        await profile.loadIfNeeded()
    }

    /// Force a fresh read of both.
    public func reload() async {
        await profile.reload()
    }

    /// Persist the current scope + presentation as the account's report
    /// profile, stamping the chosen output form into `format` where it has a
    /// representation. Adopts the server's canonical echo.
    public func save() async {
        if let format = outputForm.profileFormat {
            profile.format = format
        }
        await profile.save()
    }

    // MARK: - Expiry

    /// Pre-flight the link expiry against the three rules the server enforces
    /// (`createShareLinkSchema`): present, in the future, at most 90 days out.
    ///
    /// **Expiry is not the period.** The period bounds WHAT the recipient sees;
    /// the expiry bounds WHEN the link stops working. A 365-day period on a
    /// 30-day link is a perfectly ordinary request, so nothing here reads
    /// ``periodDays``.
    public func validateExpiry() -> [ExpiryIssue] {
        guard let expiresAt else { return [.missing] }
        let reference = now()
        guard expiresAt > reference else { return [.notInFuture] }
        let cap = calendar.date(
            byAdding: .day,
            value: Self.maxExpiryDays,
            to: reference
        ) ?? reference
        return expiresAt > cap ? [.tooFarAhead(maxDays: Self.maxExpiryDays)] : []
    }
}
