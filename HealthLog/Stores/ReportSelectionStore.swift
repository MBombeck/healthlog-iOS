import Foundation
import Observation

/// The report-selection panel's state (CU-11): the **live** leaf vocabulary, the
/// user's chosen scope, and the saved-profile round-trip behind it.
///
/// **Since 18-03 there is exactly one consumer**, and that is the point of it.
/// The doctor-report PDF and the health-record package used to share this store
/// across two screens so they could not drift into two ideas of what the user
/// chose; ``UnifiedSharingStore`` now wraps it for all four outputs, so the
/// drift has nowhere left to happen.
///
/// **The vocabulary is read, never authored.** ``vocabulary`` is
/// `GET /api/meta/capabilities` → `share.leaves` verbatim, in the server's
/// presentation order. There is no fallback list: when the server serves no
/// usable vocabulary the panel goes ``Phase/unavailable(_:)`` and says so,
/// because a locally-invented scope is exactly the defect the v2 selection
/// exists to remove.
///
/// **An empty selection is a legal answer.** `leaves: []` means *no health
/// data*, and the panel treats it as a normal state — never an error, never a
/// reason to substitute a default.
///
/// **`profile == nil` is the honest "never saved" state.** A first-open panel
/// starts with nothing chosen and waits for the user, rather than inventing a
/// scope nobody expressed.
@MainActor
@Observable
public final class ReportSelectionStore {
    /// Why the panel has nothing honest to offer.
    public enum Unavailability: Sendable, Equatable {
        /// `GET /api/meta/capabilities` failed. Carries the already-localized
        /// user-facing text of the underlying ``HLError``.
        case loadFailed(String)
        /// The server answered, but served no leaves at the grammar version
        /// this build speaks. Not recoverable client-side and NOT a cue to fall
        /// back to a local list.
        case noVocabulary
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case ready
        case unavailable(Unavailability)
    }

    /// Something the user should know about, without it being a failure.
    public enum Notice: Sendable, Equatable {
        /// The export was refused with `422 export.selection.unknown_leaf` (or
        /// the saved profile was), and the selection was rebuilt from a fresh
        /// read of the live vocabulary.
        case rebuiltFromCapabilities
        /// The saved profile carried leaf ids this server build no longer
        /// serves; they were dropped on load. Mirrors the server's own
        /// stored-blob policy (drop), never its request policy (refuse).
        case droppedRetiredLeaves(count: Int)
    }

    // MARK: - Observable state

    public private(set) var phase: Phase = .idle
    /// Live leaf ids, in the server's presentation order. THE vocabulary.
    public private(set) var vocabulary: [String] = []
    /// Selection group ids the server serves, in presentation order
    /// (`share.groups`). Surfaced for callers that want to name the sections;
    /// the capabilities payload carries the group ids but no leaf→group
    /// membership, so this store does not partition ``vocabulary`` by it.
    public private(set) var groups: [String] = []
    /// The chosen leaf ids. Membership is inclusion; absence is exclusion.
    public private(set) var chosen: Set<String> = []
    /// True once a profile has been read back or written for this account.
    public private(set) var hasSavedProfile = false
    public private(set) var notice: Notice?
    /// Already-localized text of the last save failure, or `nil`.
    public private(set) var saveError: String?
    public private(set) var isSaving = false

    /// Presentation half of the saved profile — these ride alongside the scope,
    /// never inside it. Written by the screens' pickers.
    public var format: ReportFormat = .pdf
    public var rangeDays: Int = 90
    public var includeCharts: Bool = true

    private let capabilities: ServerCapabilitiesRepository
    private let profiles: ReportSelectionRepository

    public init(capabilities: ServerCapabilitiesRepository, profiles: ReportSelectionRepository) {
        self.capabilities = capabilities
        self.profiles = profiles
    }

    // MARK: - Derived

    /// The current scope as the wire value both routes take. Ordered by the
    /// server's own catalogue order so two clients that chose the same scope
    /// send the same bytes.
    public var currentSelection: ReportSelection {
        ReportSelection(leaves: vocabulary.filter { chosen.contains($0) })
    }

    /// The scope to post, or `nil` when the panel has nothing honest to offer
    /// (still loading, or no vocabulary). Callers must not substitute a default
    /// for `nil` — an empty *selection* is a user's answer, `nil` is the absence
    /// of one.
    public var resolvedSelection: ReportSelection? {
        phase == .ready ? currentSelection : nil
    }

    public var isReady: Bool {
        phase == .ready
    }

    // MARK: - Loading

    /// Read the live vocabulary and the saved profile. Idempotent per phase:
    /// a second call while loading, or after a successful load, is a no-op —
    /// use ``reload()`` to force a fresh read.
    public func loadIfNeeded() async {
        guard phase == .idle else { return }
        await reload()
    }

    /// Force a fresh read of both the vocabulary and the saved profile.
    public func reload() async {
        phase = .loading
        let caps: ServerCapabilities
        do {
            caps = try await capabilities.fetch()
        } catch {
            phase = .unavailable(.loadFailed(Self.message(for: error)))
            return
        }
        guard caps.share.hasSelectionVocabulary else {
            vocabulary = []
            groups = caps.share.groups
            phase = .unavailable(.noVocabulary)
            return
        }
        vocabulary = caps.share.leaves
        groups = caps.share.groups

        // A profile read that fails must not take the panel down — the
        // vocabulary is what the user needs to choose at all. Absent profile
        // means "never saved", which is a legitimate starting state.
        let profile = try? await profiles.fetch()
        adopt(profile)
        phase = .ready
    }

    /// Adopt a profile (the server's canonical echo, or the stored one read
    /// back). Leaf ids the live vocabulary no longer knows are DROPPED — the
    /// server's own stored-blob policy — and the drop is surfaced rather than
    /// swallowed.
    private func adopt(_ profile: SavedReportProfile?) {
        guard let profile else {
            hasSavedProfile = false
            chosen = []
            return
        }
        hasSavedProfile = true
        format = profile.format
        rangeDays = profile.rangeDays
        includeCharts = profile.includeCharts
        let known = Set(vocabulary)
        let kept = profile.leaves.filter { known.contains($0) }
        chosen = Set(kept)
        let dropped = profile.leaves.count - kept.count
        notice = dropped > 0 ? .droppedRetiredLeaves(count: dropped) : nil
    }

    // MARK: - Editing

    public func toggle(_ leaf: String) {
        if chosen.contains(leaf) {
            chosen.remove(leaf)
        } else if vocabulary.contains(leaf) {
            chosen.insert(leaf)
        }
        notice = nil
    }

    public func isChosen(_ leaf: String) -> Bool {
        chosen.contains(leaf)
    }

    /// Admit exactly these leaf ids, ignoring any the live vocabulary does not
    /// know. Used to restore a scope (a saved profile, a rebuild) — **not** a
    /// user-facing bulk control; see the note on ``selectNone()``.
    func choose(_ leaves: some Sequence<String>) {
        let known = Set(vocabulary)
        chosen = Set(leaves.filter { known.contains($0) })
        notice = nil
    }

    /// Select nothing. Legal, and means "no health data" — not "undecided".
    ///
    /// **The narrowing half of the bulk pair.** Until Phase 18 this was the
    /// *only* bulk control, because `capabilities.share` serves the group ids
    /// without leaf→group membership, so a client cannot tell which leaves sit
    /// in the server's sensitive tier (mood, cycle, family history, the
    /// screener totals) — and a blanket bulk-on would then be one tap that
    /// ships mental-health scores to a clinician.
    ///
    /// That reasoning still holds and is why the widening half does **not**
    /// live here. Decision E1.2 (2026-08-22) answered the convenience the
    /// operator asked for with an explicit act on the unified sharing surface
    /// — ``UnifiedSharingStore/selectAll()`` — which names what a full
    /// selection contains at the moment the user performs it, next to the
    /// control. The default preselection stays EMPTY; see
    /// ``UnifiedSharingStore/defaultSelection`` for the whole rationale before
    /// changing either half.
    public func selectNone() {
        chosen = []
        notice = nil
    }

    public func clearNotice() {
        notice = nil
    }

    // MARK: - Saving

    /// Replace the account's saved report profile with the current panel state.
    /// Adopts the server's canonical echo (it persists catalogue ordering).
    public func save() async {
        guard phase == .ready else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let saved = try await profiles.replace(
                SavedReportProfile(
                    selection: currentSelection,
                    format: format,
                    rangeDays: rangeDays,
                    includeCharts: includeCharts
                )
            )
            adopt(saved)
        } catch ReportSelectionError.unknownLeaves {
            await rebuildFromCapabilities()
        } catch {
            saveError = Self.message(for: error)
        }
    }

    // MARK: - 422 recovery

    /// Handle an error thrown by an export call. Returns `true` when it was the
    /// `422 export.selection.unknown_leaf` contract mismatch and the selection
    /// has been rebuilt from a fresh read of the live vocabulary — the caller
    /// should then show ``notice`` and let the user retry, not surface a raw
    /// error.
    @discardableResult
    public func handleExportFailure(_ error: Error) async -> Bool {
        guard HealthRecordExportError.mapped(error) as? HealthRecordExportError == .unknownLeaf else {
            return false
        }
        await rebuildFromCapabilities()
        return true
    }

    /// Re-read the live vocabulary and narrow the chosen scope to it. Never
    /// widens: a leaf the server dropped simply stops being part of the
    /// selection, and the user is told it happened.
    func rebuildFromCapabilities() async {
        guard let caps = try? await capabilities.fetch(), caps.share.hasSelectionVocabulary else {
            phase = .unavailable(.noVocabulary)
            return
        }
        vocabulary = caps.share.leaves
        groups = caps.share.groups
        chosen = chosen.intersection(caps.share.leaves)
        phase = .ready
        notice = .rebuiltFromCapabilities
    }

    private static func message(for error: Error) -> String {
        (error as? HLError)?.userFacingDescription
            ?? String(localized: "Couldn't load the selection. Please try again.")
    }
}
