import Foundation
import Observation

@MainActor
@Observable
public final class AchievementsStore {
    public private(set) var achievements: [Achievement] = []
    public private(set) var isLoading: Bool = false
    public private(set) var error: HLError?

    private let repo: AchievementsRepository

    /// A2-M4 — appear-revalidation freshness gate (60s TTL).
    @ObservationIgnored private var revalidationGate = RevalidationGate(ttl: 60)

    public init(repo: AchievementsRepository) {
        self.repo = repo
    }

    public var unlockedCount: Int {
        achievements.filter(\.unlocked).count
    }

    public var totalCount: Int {
        achievements.count
    }

    /// Sum of `points` across **unlocked** achievements. Hidden achievements
    /// that are unlocked count too — the server reveals them once unlocked,
    /// so the points are real.
    public var earnedPoints: Int {
        achievements.reduce(0) { acc, a in
            acc + (a.unlocked ? (a.points ?? 0) : 0)
        }
    }

    /// Sum of `points` across **every visible (non-hidden-placeholder)**
    /// achievement. Hidden placeholders that the user has not yet unlocked
    /// are skipped so the denominator stays honest — the user can't see
    /// what those badges are worth without unlocking them.
    public var totalPoints: Int {
        achievements.reduce(0) { acc, a in
            // Skip hidden placeholders (HelpCircle sentinel) to keep the
            // denominator honest: showing "X / 9999" with 6 invisible-but-
            // pointed cards looks misleading. Once unlocked, hidden cards
            // surface with their real definition and contribute normally.
            acc + ((a.isHiddenPlaceholder && !a.unlocked) ? 0 : (a.points ?? 0))
        }
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            achievements = try await repo.list()
            revalidationGate.markLoaded()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// A2-M4 — appear-revalidation entry point: reload when empty (cold) OR
    /// stale (partial-then-stale), no-op inside the freshness window.
    public func revalidateIfStale() async {
        if achievements.isEmpty || revalidationGate.isStale() {
            await load()
        }
    }

    public func clearOnLogout() {
        achievements = []
        error = nil
    }
}
