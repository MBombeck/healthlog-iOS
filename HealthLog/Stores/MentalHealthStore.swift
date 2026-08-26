import Foundation
import Observation

/// `@MainActor @Observable` store backing the opt-in mental-health screener
/// surface (v1.25 `W-MENTAL-HEALTH`; PHQ-9 / GAD-7). Loads the history via
/// ``MentalHealthRepository`` and drives one administration through
/// choose → form → result.
///
/// **SAFETY (item-9 crisis path).** The crisis card is gated STRICTLY on the
/// item-9 flag (`items[8] > 0`), never on the total / band. On submit the store
/// computes the LOCAL flag immediately, so the crisis card surfaces the instant
/// the user submits — even if the upload fails / is offline. When the server
/// returns its locale-aware `crisis` set, that is rendered; when the set is
/// absent (offline, or deploy skew where `item9Flagged` is true but `crisis` is
/// null) the store resolves the bundled ``CrisisResourceFallback``. A positive
/// item-9 NEVER goes unsignposted.
///
/// **HARD invariants (mirror server).** Showing resources triggers NO third-party
/// alert, NO contact / emergency-contact notification, NO email, NO analytics. The
/// item answers + the item-9 flag are NEVER logged (no os_log line carries either)
/// — the only private signpost is `MentalHealthSignpost` (boolean-free, name
/// only). The framing is calm; the copy is mirrored verbatim and never softened
/// or escalated here (it lives in `Localizable.xcstrings`).
///
/// **PHI.** The submitted item answers live in-memory only until the POST
/// resolves (then dropped); they are never written to SwiftData / UserDefaults /
/// logs. The history holds only the derived DTO (the server never returns items).
/// Conforms to `LogoutClearable` so the cascade wipes everything on logout.
@MainActor
@Observable
public final class MentalHealthStore {
    /// The three-phase flow (mirrors the web `mental-wellbeing.tsx`).
    public enum Phase: Sendable, Equatable {
        case choose
        case form
        case result
    }

    public private(set) var phase: Phase = .choose
    /// Screener history (newest-first). Derived DTOs only — no item answers.
    public private(set) var history: [MentalHealthAssessmentDTO] = []
    public private(set) var isLoading = false
    public private(set) var isSubmitting = false
    public private(set) var lastError: String?

    /// Per-instrument detail state. `beginDetail` seeds this synchronously from
    /// the offline-readable unfiltered history before `loadDetail` refreshes the
    /// same instrument through the repository's filtered server query.
    public private(set) var detailInstrument: MentalHealthInstrument?
    public private(set) var detailHistory: [MentalHealthAssessmentDTO] = []
    public private(set) var isDetailLoading = false
    public private(set) var detailError: String?

    /// The instrument being administered in the `.form` / `.result` phase.
    public private(set) var activeInstrument: MentalHealthInstrument = .phq9
    /// In-flight per-item answers (0–3; `-1` = unanswered). PHI — held only until
    /// the result is rendered, never persisted / logged.
    public private(set) var answers: [Int] = []
    /// Optional functional-impairment follow-up (0–3; not scored). PHI.
    public private(set) var functionalDifficulty: Int?

    /// The rendered result. `serverDerived == false` marks a PROVISIONAL offline
    /// result (locally-summed; will sync). `crisis` is non-nil iff the item-9 flag
    /// was set — resolved from the server set when present, else the bundled
    /// fallback.
    public private(set) var result: Result?

    public struct Result: Sendable, Equatable {
        public let instrument: MentalHealthInstrument
        public let totalScore: Int
        public let severityBand: String
        public let actionThreshold: Int
        public let item9Flagged: Bool
        public let crisis: CrisisResourceSet?
        /// `true` when the result came from the server 201; `false` when it is the
        /// provisional offline fallback (upload failed / queued).
        public let serverDerived: Bool

        /// The gentle nudge shows on the concerning side of the threshold. The
        /// THRESHOLD is the server's (`actionThreshold` from the POST response,
        /// carried above) — the client never substitutes a number of its own for
        /// a result the server already evaluated. Only the DIRECTION is local,
        /// because the wire does not carry it: the inverted WHO-5 and SCI flag the
        /// LOW side (`total <= threshold`), the PHQ/GAD distress scales the high
        /// side. On the PROVISIONAL offline result `actionThreshold` is the
        /// mirrored constant — the only case where a bundled number is used, and
        /// that result is already labelled provisional in the UI.
        public var showConsiderProfessional: Bool {
            instrument.needsFollowUp(forTotal: totalScore, threshold: actionThreshold)
        }
    }

    private let repository: MentalHealthRepository
    /// The app's presented display language ("de" / "en"), sent to the server +
    /// used to resolve the bundled crisis fallback. Mirrors the web sending its
    /// i18n locale (NOT the region), so a plain-"en" user gets the international
    /// set, a "de" user gets TelefonSeelsorge (server-confirmed mapping).
    private let presentedLocale: String
    private var isReloading = false
    private var detailLoadID: UUID?

    /// #39 — client-provenance value sent on every submit (`assessmentSourceEnum`
    /// on the server; `"IOS"`, not `"iOS"`).
    static let clientSource = "IOS"

    public init(
        repository: MentalHealthRepository,
        presentedLocale: String = MentalHealthStore.deviceDisplayLocale()
    ) {
        self.repository = repository
        self.presentedLocale = presentedLocale
    }

    /// The app's effective UI language ("de" / "en") — the bundle's first
    /// preferred localization. Matches what the questionnaire wording is shown in.
    public static func deviceDisplayLocale() -> String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    // MARK: - Load

    /// Load the screener history. No-op while a reload is already in flight.
    public func load() async {
        guard !isReloading else { return }
        isReloading = true
        isLoading = true
        defer {
            isLoading = false
            isReloading = false
        }
        do {
            history = try await repository.history()
            lastError = nil
        } catch {
            applyError(error)
        }
    }

    // MARK: - Instrument detail

    /// Open an instrument detail with an immediate cache-derived snapshot.
    public func beginDetail(_ instrument: MentalHealthInstrument) {
        detailLoadID = nil
        detailInstrument = instrument
        detailHistory = history.filter { $0.instrument == instrument }
        detailError = nil
        isDetailLoading = false
    }

    /// Refresh one instrument through the repository's server-side filter. A
    /// failed refresh leaves the seeded rows intact for offline continuity.
    public func loadDetail(_ instrument: MentalHealthInstrument) async {
        if detailInstrument != instrument {
            beginDetail(instrument)
        }
        guard !isDetailLoading else { return }
        let loadID = UUID()
        detailLoadID = loadID
        isDetailLoading = true
        detailError = nil
        defer {
            if detailLoadID == loadID {
                isDetailLoading = false
            }
        }

        do {
            let rows = try await repository.history(instrument: instrument, limit: 200)
            guard detailInstrument == instrument, detailLoadID == loadID else { return }
            detailHistory = rows
        } catch {
            guard detailInstrument == instrument, detailLoadID == loadID else { return }
            detailError = LogSanitizer.redact(String(describing: error))
        }
    }

    // MARK: - Flow

    /// Begin an administration: reset the answers to `instrument.itemCount`
    /// unanswered slots and move to the form.
    public func begin(_ instrument: MentalHealthInstrument) {
        activeInstrument = instrument
        answers = Array(repeating: -1, count: instrument.itemCount)
        functionalDifficulty = nil
        result = nil
        lastError = nil
        phase = .form
    }

    /// Return to the instrument chooser (discards the in-flight answers).
    public func backToChoose() {
        answers = []
        functionalDifficulty = nil
        result = nil
        lastError = nil
        phase = .choose
    }

    /// Record an answer for a scored item. The valid range is instrument-driven
    /// (PHQ/GAD 0–3, WHO-5 0–5) — never hardcode the ceiling.
    public func setAnswer(_ value: Int, at index: Int) {
        guard index >= 0, index < answers.count, (0 ... activeInstrument.itemMax).contains(value) else { return }
        answers[index] = value
    }

    /// Record or clear PHQ-9's optional functional-impairment follow-up.
    public func setFunctionalDifficulty(_ value: Int?) {
        guard activeInstrument.showsFunctionalFollowUp else {
            functionalDifficulty = nil
            return
        }
        if let value, !(0 ... 3).contains(value) { return }
        functionalDifficulty = value
    }

    /// True once every scored item is answered (the functional follow-up stays
    /// optional). Drives the submit button's enabled state.
    public var isComplete: Bool {
        !answers.isEmpty && answers.allSatisfy { $0 >= 0 }
    }

    /// True once the running administration holds at least one entered answer
    /// (a scored item or the functional follow-up). Drives the "Test abbrechen?"
    /// confirm on the form's back-out: when nothing has been entered there is
    /// nothing to lose, so the back-out skips the dialog.
    public var hasAnswers: Bool {
        answers.contains { $0 >= 0 } || functionalDifficulty != nil
    }

    // MARK: - Submit

    /// Submit the administration. The LOCAL item-9 flag is computed up-front so the
    /// crisis card surfaces immediately regardless of upload success. On the 201
    /// the server-authoritative total / band / crisis are rendered; on a retriable
    /// failure (durably queued) a PROVISIONAL offline result is rendered WITH the
    /// crisis card from the bundled fallback when item-9 is flagged.
    public func submit() async {
        guard isComplete, !isSubmitting else { return }
        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }

        let instrument = activeInstrument
        let items = answers
        // SAFETY: local item-9 flag, computed BEFORE the network so a positive
        // item-9 is signposted even if the upload fails. Never logged — the
        // signpost below carries NO flag value / NO PII.
        let localFlag = instrument.isSafetyFlagged(items: items)
        MentalHealthSignpost.submitStarted()

        // #39 — a STABLE per-administration id, minted once here. It is both the
        // body `externalId` (durable >24h server dedup) and, downstream, the
        // idempotency-key header — so an outbox replay after the 24h header window
        // still collapses to the same administration instead of double-submitting.
        let externalId = UUID().uuidString
        let body = CreateAssessmentRequest(
            instrument: instrument,
            items: items,
            functionalDifficulty: functionalDifficulty,
            locale: presentedLocale,
            source: Self.clientSource,
            externalId: externalId
        )

        do {
            let response = try await repository.submit(body)
            applyServerResult(response)
            // Drop the in-memory PHI answers — the result is now derived-only.
            answers = []
            functionalDifficulty = nil
            phase = .result
            await load()
        } catch let err as HLError where err.shouldPersistToOutbox {
            // Durably queued — render a PROVISIONAL offline result. Crucially, if
            // item-9 was flagged locally, STILL surface the crisis card from the
            // bundled fallback (the signpost must not wait on connectivity).
            applyOfflineResult(instrument: instrument, items: items, item9Flagged: localFlag)
            answers = []
            functionalDifficulty = nil
            phase = .result
            lastError = nil
        } catch {
            // SAFETY (C1): a positive item-9 MUST surface the crisis card on EVERY
            // terminal outcome — including a NON-retriable failure that bypasses the
            // outbox branch above: `.decoding` (a 201 the server persisted but whose
            // envelope shape drifted — the exact deploy-skew the fallback exists
            // for), `.server` 4xx (400/403/409/422), `.canceled`, `.unknown`. The
            // local item-9 flag was computed pre-network (line above), so render a
            // PROVISIONAL result + the bundled fallback crisis here too. The crisis
            // resources must NEVER depend on the upload succeeding.
            //
            // Deliberately do NOT enqueue on this branch: a `.decoding` failure means
            // the write may already have landed server-side (HTTP 201, body unread),
            // so re-queuing would risk a double-write — the no-double-write contract
            // (`HLError.shouldPersistToOutbox`) intentionally excludes `.decoding`.
            if localFlag {
                applyOfflineResult(instrument: instrument, items: items, item9Flagged: true)
                answers = []
                functionalDifficulty = nil
                phase = .result
            }
            // Still record the (sanitized) soft error so the sync failure is honest.
            applyError(error)
        }
    }

    /// Restore the bundled crisis set for a flagged HISTORY row (history never
    /// carries the set). Used by the history-row "resources" affordance.
    public func crisisSet(forHistoryRow row: MentalHealthAssessmentDTO) -> CrisisResourceSet {
        CrisisResourceFallback.forLocale(row.locale.isEmpty ? presentedLocale : row.locale)
    }

    // MARK: - Result builders

    private func applyServerResult(_ response: CreateAssessmentResponse) {
        let a = response.assessment
        // SAFETY net for deploy skew: server says flagged but omitted `crisis` →
        // resolve the bundled fallback (anchored on the DEVICE display language the
        // user actually saw — the server echoes the same value we sent) so the
        // signpost still appears.
        let crisis: CrisisResourceSet? = if a.item9Flagged {
            response.crisis ?? CrisisResourceFallback.forLocale(presentedLocale)
        } else {
            response.crisis // honour an (unexpected) server set even when flag is false; nil otherwise
        }
        result = Result(
            instrument: a.instrument,
            totalScore: a.totalScore,
            severityBand: a.severityBand,
            actionThreshold: response.actionThreshold,
            item9Flagged: a.item9Flagged,
            crisis: crisis,
            serverDerived: true
        )
    }

    private func applyOfflineResult(instrument: MentalHealthInstrument, items: [Int], item9Flagged: Bool) {
        // Instrument-aware total: WHO-5 reports raw-sum × 4 (0–100 %), the others
        // the raw sum. Matches the server's `scoreTotal`.
        let total = instrument.scoreTotal(items: items)
        result = Result(
            instrument: instrument,
            totalScore: total,
            severityBand: instrument.severityBand(forTotal: total),
            actionThreshold: instrument.actionThreshold,
            item9Flagged: item9Flagged,
            crisis: item9Flagged ? CrisisResourceFallback.forLocale(presentedLocale) : nil,
            serverDerived: false
        )
    }

    // MARK: - Logout

    /// Drop every in-memory snapshot (history + in-flight PHI answers + result) on
    /// logout so the next user never inherits the predecessor's screener data.
    public func clearOnLogout() {
        history = []
        detailInstrument = nil
        detailHistory = []
        detailError = nil
        isDetailLoading = false
        detailLoadID = nil
        answers = []
        functionalDifficulty = nil
        result = nil
        phase = .choose
        isLoading = false
        isReloading = false
        isSubmitting = false
        lastError = nil
    }

    /// Test-only — seed the in-memory history without a network round-trip so the
    /// logout-wipe suite can prove `clearOnLogout` purges it.
    func seedForTesting(history: [MentalHealthAssessmentDTO]) {
        self.history = history
    }

    /// Test-only — drive an offline-failure submit deterministically (the
    /// in-flight answers are taken as given) so the crisis-on-upload-failure path
    /// can be asserted without a network stub.
    func applyOfflineResultForTesting(instrument: MentalHealthInstrument, items: [Int]) {
        applyOfflineResult(instrument: instrument, items: items, item9Flagged: instrument.isSafetyFlagged(items: items))
        phase = .result
    }

    // MARK: - Private

    private func applyError(_ error: Error) {
        // SAFETY: only a sanitized error description — never the items / flag.
        lastError = LogSanitizer.redact(String(describing: error))
    }
}
