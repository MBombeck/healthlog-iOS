import Foundation
import Observation

/// **LIFE (1.5.0, #132, Server #614)** — state of the "Life circumstances"
/// screen.
///
/// Built per screen in its `.task` and gone with it, like
/// ``AnamnesisFactsStore``: no answer about a person's life outlives the
/// screen or a change of account, and nothing is written to disk. A refresh
/// that fails keeps the last loaded answers on screen (stale while
/// revalidate in memory) and says so.
///
/// The store computes nothing medical. It picks the verb of each write from
/// the current revision (``LifeSectionDraft``), reloads after every save
/// because a correction mints a new revision id, and shows the derived values
/// exactly as the server sent them.
@MainActor
@Observable
public final class LifeCircumstancesStore {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        /// The first load failed; nothing to show.
        case failed(String)
        /// The record or the module is off for this person; the server's
        /// reason when one can be named.
        case disabled(String?)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var payload: LifeCircumstances?
    /// A refresh failed while older answers are on screen.
    public private(set) var isStale = false
    /// The section whose save is in flight.
    public private(set) var savingSection: LifeSectionKey?
    /// An AI switch or a "still true" write is in flight.
    public private(set) var isUpdatingSettings = false
    /// The reason the last write of a section failed, by section.
    public private(set) var sectionErrors: [LifeSectionKey: String] = [:]
    /// One sentence about the page as a whole (the AI switch conflict).
    public private(set) var notice: String?
    /// POLISH-C (C7) — the one-word alcohol answer from before AUDIT-C, when
    /// the record still holds one this build can name. Read only from a
    /// server that has AUDIT-C (``LifeCircumstancesStore/loadLegacyAlcohol()``).
    public internal(set) var legacyAlcohol: AnamnesisFactRevision?
    /// The editable answers, by section. Rebuilt from the server only when
    /// the answers there changed, so a failed save keeps what was typed.
    public var drafts: [LifeSectionKey: LifeSectionDraft] = [:]

    private var draftBase: [LifeSectionKey: [String]] = [:]
    private var aiToken: String?
    let repo: LifeCircumstancesRepository

    public init(repo: LifeCircumstancesRepository) {
        self.repo = repo
    }

    // MARK: - Load

    public func load() async {
        if payload == nil { phase = .loading }
        async let token = repo.aiSectionsToken()
        do {
            let loaded = try await repo.load()
            apply(loaded)
            aiToken = await token
            await loadLegacyAlcohol()
            isStale = false
            phase = .loaded
        } catch {
            _ = await token
            handleLoadFailure(error)
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if let refusal = Self.refusal(for: error) {
            payload = nil
            phase = refusal
            return
        }
        if payload != nil {
            isStale = true
            phase = .loaded
        } else {
            phase = .failed((error as? HLError)?.userFacingDescription ?? String(localized: "life.loadError"))
        }
    }

    /// `403 module.disabled` and a refused record (a sharing grant without
    /// the profile) are not failures: the surface is off. `nil` otherwise.
    nonisolated static func refusal(for error: Error) -> Phase? {
        switch error as? HLError {
        case .moduleDisabled:
            .disabled(nil)
        case let .server(status, _, _) where status == 403:
            .disabled(ModuleAccessState.notGranted.offReason)
        default:
            nil
        }
    }

    private func apply(_ loaded: LifeCircumstances) {
        payload = loaded
        for section in loaded.sections {
            let base = section.facts.map { "\($0.id):\($0.kind.rawValue)" }
            if drafts[section.key] == nil || draftBase[section.key] != base {
                drafts[section.key] = LifeSectionDraft(section: section)
                draftBase[section.key] = base
            }
        }
    }

    // MARK: - Save a section

    /// Writes the section's draft. `validFrom` (a calendar day) dates the new
    /// answers back; `nil` means from now. Returns `true` when every write
    /// went through.
    @discardableResult
    public func save(_ key: LifeSectionKey, validFrom: Date? = nil, calendar: Calendar = .current) async -> Bool {
        guard savingSection == nil, let section = payload?.section(key), let draft = draft(key) else { return false }
        let day = validFrom.map { Self.dayString($0, calendar: calendar) }
        let writes = draft.writes(against: section, validFrom: day)
        guard !writes.isEmpty else { return true }
        savingSection = key
        sectionErrors[key] = nil
        defer { savingSection = nil }
        var failure: AnamnesisFactFailure?
        for write in writes {
            do {
                try await repo.apply(write)
            } catch {
                failure = AnamnesisFactFailure.from(error)
                break
            }
        }
        if let failure {
            sectionErrors[key] = failure.userFacingDescription
            // A dead revision id needs fresh ones; a partial save needs the
            // truth. Both are a reload; the typed answers stay unless the
            // server's answers changed underneath them.
            await reload()
            return false
        }
        // Saved: the form starts again from what the server now holds.
        draftBase[key] = nil
        await reload()
        return true
    }

    /// `YYYY-MM-DD` of `date` in `calendar`'s zone.
    nonisolated static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The section's editable answers; built from the server when none exist.
    public func draft(_ key: LifeSectionKey) -> LifeSectionDraft? {
        drafts[key] ?? payload?.section(key).map(LifeSectionDraft.init(section:))
    }

    /// `true` when a save of this section would send at least one write.
    public func hasChanges(_ key: LifeSectionKey) -> Bool {
        guard let section = payload?.section(key), let draft = draft(key) else { return false }
        return draft.hasChanges(against: section)
    }

    // MARK: - AI switches

    /// Switches one AI section (`aiSection` of a section, or `SHIFT_SCHEDULE`).
    /// A stale token (`409 about_me_conflict`) reloads the page and says so;
    /// it is not retried, because the other write may have been the person's
    /// own decision on another device.
    public func setAI(_ aiSection: String, included: Bool) async {
        guard !isUpdatingSettings else { return }
        isUpdatingSettings = true
        notice = nil
        defer { isUpdatingSettings = false }
        do {
            aiToken = try await repo.setAISections([aiSection: included], baseUpdatedAt: aiToken)
            await reload()
        } catch let HLError.server(status, code, _) where status == 409 && code == OptimisticConflictCode.aboutMe {
            notice = String(localized: "life.ai.conflict")
            await reload()
        } catch {
            notice = String(localized: "life.ai.saveError")
        }
    }

    // MARK: - Still true

    public func confirm(_ key: LifeSectionKey) async {
        guard !isUpdatingSettings else { return }
        isUpdatingSettings = true
        notice = nil
        defer { isUpdatingSettings = false }
        do {
            try await repo.confirm(key)
            await reload()
        } catch {
            notice = String(localized: "life.review.confirmError")
        }
    }

    public func clearNotice() {
        notice = nil
    }

    // MARK: - Private

    /// Quiet reload after a write: the page stays, a failure marks it stale.
    private func reload() async {
        async let token = repo.aiSectionsToken()
        do {
            try await apply(repo.load())
            aiToken = await token
            isStale = false
        } catch {
            _ = await token
            if let refusal = Self.refusal(for: error) {
                payload = nil
                phase = refusal
            } else {
                isStale = true
            }
        }
    }
}
