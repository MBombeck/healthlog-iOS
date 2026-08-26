import Foundation

/// **v1.35.0 (GH #83) — drives Settings → Health Score.**
///
/// Holds the server's resolved composition, the person's in-progress selection,
/// and — when the server refused a selection — the reason it gave, so the
/// screen can explain the limit rather than report a failure.
///
/// **Nothing here decides what is allowed.** The lower bound is a count of
/// *fields of health*, not of pillars, and which pillar speaks to which field
/// is server knowledge that rides no wire. So this store never predicts a
/// refusal, never greys out a save it cannot justify, and never rewords the
/// server's verdict into one of its own.
@MainActor
@Observable
public final class HealthScoreConfigStore {
    /// The last composition the server resolved. `nil` until the first load.
    public private(set) var config: HealthScoreConfig?
    /// The pillars currently ticked on screen. Seeded from ``config`` and then
    /// owned by the person until a save lands.
    public private(set) var selection: Set<HealthScorePillar> = []
    public private(set) var isLoading = false
    /// The load failed and there is nothing to show — the screen offers a retry.
    public private(set) var loadFailed = false
    public private(set) var isSaving = false
    public private(set) var outcome: SaveOutcome = .idle

    private let repo: HealthScoreConfigRepository

    public init(repo: HealthScoreConfigRepository) {
        self.repo = repo
    }

    /// What the last save attempt produced.
    public enum SaveOutcome: Sendable, Equatable {
        case idle
        case saved
        /// The server refused the selection and said which rule it missed.
        /// **Not a failure** — the screen renders an explanation of the limit.
        case refused(HealthScoreBreadthReason)
        /// Something went wrong on the way. Carries user-facing copy already
        /// resolved by ``HLError/userFacingDescription``.
        case failed(String)
    }

    /// The catalogue the screen lists, in the server's registry order. Any
    /// pillar the server knows but this build does not still shows up, because
    /// a resolved config that carries it must round-trip unchanged rather than
    /// be silently dropped by a save.
    public var offeredPillars: [HealthScorePillar] {
        var pillars = HealthScorePillar.known
        guard let config else { return pillars }
        let extras = (config.pillars + config.excludedPillars)
            .filter { pillar in !pillars.contains(pillar) }
        for extra in extras where !pillars.contains(extra) {
            pillars.append(extra)
        }
        return pillars
    }

    /// `true` when the ticked set differs from the one the server last
    /// resolved. The save is offered only then — re-sending an unchanged
    /// selection would bump the recipe version and draw a series break for
    /// nothing.
    public var hasChanges: Bool {
        guard let config else { return false }
        return selection != Set(config.pillars)
    }

    public func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let fresh = try await repo.fetch()
            adopt(fresh)
        } catch {
            loadFailed = config == nil
            if config != nil, let err = error as? HLError {
                outcome = .failed(err.userFacingDescription)
            }
        }
    }

    /// Tick or untick one pillar. Purely local until ``save()``.
    public func toggle(_ pillar: HealthScorePillar, isOn: Bool) {
        if isOn {
            selection.insert(pillar)
        } else {
            selection.remove(pillar)
        }
        // A refusal describes the selection that was sent, not the one being
        // built. Clear it the moment the person changes something, or the
        // explanation outlives what it explained.
        outcome = .idle
    }

    public func isOn(_ pillar: HealthScorePillar) -> Bool {
        selection.contains(pillar)
    }

    /// Send the ticked selection. Registry order is restored on the way out so
    /// the body reads the way the server's own catalogue does.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        outcome = .idle
        defer { isSaving = false }
        let ordered = offeredPillars.filter { selection.contains($0) }
        do {
            let fresh = try await repo.update(pillars: ordered)
            adopt(fresh)
            outcome = .saved
        } catch let error as HLError {
            outcome = Self.outcome(for: error)
        } catch {
            outcome = .failed(String(localized: "Couldn't save your selection. Please try again."))
        }
    }

    /// Map a write failure onto what the screen should say. A refusal is
    /// separated out here so the view never has to know a wire code.
    private static func outcome(for error: HLError) -> SaveOutcome {
        if case let .refusedWithReason(code, reason) = error,
           code == HealthScoreConfigErrorCode.tooNarrow
        {
            return .refused(HealthScoreBreadthReason(rawValue: reason))
        }
        return .failed(error.userFacingDescription)
    }

    private func adopt(_ fresh: HealthScoreConfig) {
        config = fresh
        selection = Set(fresh.pillars)
        loadFailed = false
    }

    public func clearOnLogout() {
        config = nil
        selection = []
        loadFailed = false
        outcome = .idle
    }
}
