import Foundation
import Observation

/// **CU-35 (2) — the optional practice-name prefill on the health report.**
///
/// `POST /api/export/health-record` has always accepted an optional
/// `practiceName` (it prints on the PDF), but iOS never offered a field for it,
/// so every report went out without one. Server v1.32.35 started filling
/// `lastReportPracticeName` on `GET /api/auth/me` with real values — which
/// makes an *optional prefill* possible for the first time.
///
/// ## Why the prefill needs a rule and not just an assignment
///
/// The server field is **last-used, not per-device**: whoever generated the
/// most recent report wins, whether that was the web session, another device,
/// or a visit to an entirely different practice six months ago. It is therefore
/// a convenience, never an authority, and it carries one hard invariant:
///
/// > **A prefill must never silently overwrite what the person typed.**
///
/// Three rules enforce it, and all three matter:
///
/// 1. **Once.** ``applyPrefill(_:)`` fires at most once per store. A later
///    `/me` refresh (a foreground revalidate, a second `.task`) cannot come
///    back and re-stamp a field the user has since curated.
/// 2. **Only into an untouched field.** Once ``setDraftFromUser(_:)`` has been
///    called, the field belongs to the user and the prefill is dead — *even if
///    they cleared it back to empty*. Deleting the suggestion is an answer
///    ("no practice name on this one"), and re-inserting it would be the exact
///    silent overwrite this rule exists to prevent.
/// 3. **Only over emptiness.** A non-empty draft is never replaced, whatever
///    put it there.
///
/// The blank / whitespace-only server value is treated as absence, so an
/// account that once saved `"   "` does not get a space prefilled.
@MainActor
@Observable
public final class ReportPracticeNameStore {
    /// The text-field contents. Written by ``setDraftFromUser(_:)`` (the user)
    /// or exactly once by ``applyPrefill(_:)`` (the server suggestion).
    public private(set) var draft: String = ""
    /// True once the server suggestion was actually applied — drives the "we
    /// filled this in from your last report" hint, so the value never appears
    /// as if the user had typed it.
    public private(set) var didPrefill = false
    /// True once the user has touched the field. Latches: clearing the field
    /// does NOT hand it back to the prefill.
    public private(set) var userEdited = false

    private let repo: SettingsRepository

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    /// What to send with the report, or `nil` when the field is blank. The
    /// server treats the key as optional and ``HealthRecordExportRequest``
    /// omits it entirely rather than sending `null` (the schema is `.strict()`).
    public var practiceName: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The user typed. Latches ``userEdited`` — from here on no prefill applies.
    public func setDraftFromUser(_ value: String) {
        guard value != draft else { return }
        draft = value
        userEdited = true
    }

    /// Apply the server's `lastReportPracticeName`, honouring all three rules
    /// above. Returns whether it actually landed (the tests assert on this, and
    /// so does the hint).
    @discardableResult
    public func applyPrefill(_ serverValue: String?) -> Bool {
        guard !didPrefill, !userEdited, draft.isEmpty else { return false }
        guard let trimmed = serverValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else
        {
            // Nothing to suggest. Deliberately NOT latching `didPrefill`: the
            // account may generate its first report elsewhere while this screen
            // is open, and a later load may then legitimately suggest one.
            return false
        }
        draft = trimmed
        didPrefill = true
        return true
    }

    /// Read `GET /api/auth/me` and offer its `lastReportPracticeName` as the
    /// prefill.
    ///
    /// **Fail-soft, and cheap to call twice.** A transport failure leaves the
    /// field exactly as it is — an empty practice-name box is a perfectly good
    /// state, and no report is blocked by it. The load short-circuits once the
    /// field is spoken for, so re-entering the screen never costs a round-trip
    /// it cannot use.
    public func loadPrefill() async {
        guard !didPrefill, !userEdited, draft.isEmpty else { return }
        guard let prefs = try? await repo.authMeServerPrefs() else { return }
        applyPrefill(prefs.lastReportPracticeName)
    }

    /// Drop everything on logout — the practice name is another account's now.
    public func clearOnLogout() {
        draft = ""
        didPrefill = false
        userEdited = false
    }
}
