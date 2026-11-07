import Foundation
import Observation
import UIKit

/// **AUDITC (1.5.0, #132)** — the state of the AUDIT-C form and of the
/// removal question, beside the alcohol section.
///
/// Held by the section card, so it lives as long as the screen: closing the
/// section keeps the chosen answers and, after a failed attempt, the retry
/// identity. The model counts nothing medical; it passes the points the
/// server numbered each answer with and shows what the server scored.
///
/// A submission is fixed at its first attempt (`externalId`, `takenAt`, the
/// offered `locale`). A retry with the same answers sends the same entry, and
/// the server's 200 replay is success like the 201. Changed answers are a new
/// entry with a new identity. A 422 means the entry was not stored: the page
/// reloads, and if the server now offers another wording the answers start
/// over, because they belonged to the old one.
@MainActor
@Observable
final class AuditCModel {
    /// The form is unfolded under the result.
    var isFormOpen = false
    /// The chosen points per item, `nil` while unanswered.
    private(set) var answers: [Int?] = []
    private(set) var isSubmitting = false
    /// Why the last attempt failed, in one sentence.
    private(set) var submitError: String?
    /// The history entry whose removal is being asked about, in place.
    var confirmingRemovalID: String?
    private(set) var removingID: String?
    private(set) var removeError: String?

    /// The entry of the last failed attempt, sent again by a retry.
    private(set) var pending: AuditCSubmission?
    /// The wording the current answers were given to.
    private var answeredLocale: String?

    // MARK: - Form

    func open(_ instrument: AuditCInstrument) {
        if answeredLocale != instrument.locale || answers.count != instrument.items.count {
            startOver(instrument)
        }
        submitError = nil
        isFormOpen = true
    }

    func cancel() {
        isFormOpen = false
        submitError = nil
        answers = answers.map { _ in nil }
        pending = nil
    }

    func select(_ value: Int, item index: Int) {
        guard answers.indices.contains(index), !isSubmitting else { return }
        answers[index] = value
    }

    func answer(_ index: Int) -> Int? {
        answers.indices.contains(index) ? answers[index] : nil
    }

    var isComplete: Bool {
        !answers.isEmpty && answers.allSatisfy { $0 != nil }
    }

    /// Sends the answers in the wording `instrument` offered. Returns `true`
    /// once the server holds the entry (201, or 200 for a replay).
    @discardableResult
    func submit(
        _ instrument: AuditCInstrument,
        store: LifeCircumstancesStore,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) async -> Bool {
        guard !isSubmitting, isComplete, answers.count == instrument.items.count,
              answeredLocale == instrument.locale else { return false }
        let items = answers.compactMap(\.self)
        let submission: AuditCSubmission = if let pending, pending.items == items, pending.locale == instrument.locale {
            pending
        } else {
            AuditCSubmission(
                items: items,
                takenAt: now,
                timeZone: timeZone.identifier,
                locale: instrument.locale,
                externalId: UUID().uuidString.lowercased()
            )
        }
        pending = submission
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }
        do {
            _ = try await store.submitAuditC(submission)
            pending = nil
            isFormOpen = false
            answers = answers.map { _ in nil }
            Self.announce(String(localized: "life.auditC.saved"))
            return true
        } catch {
            submitError = Self.submitMessage(for: error)
            if case .server(422, _, _)? = error as? HLError {
                // Not stored: a later attempt is a new entry. The page
                // reloads; another wording on offer now means the answers
                // were given to a wording the server no longer takes.
                pending = nil
                await store.load()
                if let fresh = store.auditC?.instrument, fresh.locale != submission.locale {
                    startOver(fresh)
                }
            }
            return false
        }
    }

    nonisolated static func submitMessage(for error: Error) -> String {
        switch error as? HLError {
        case .server(422, _, _)?:
            String(localized: "life.auditC.error.invalid")
        case .rateLimited?, .server(429, _, _)?:
            String(localized: "life.auditC.error.rateLimited")
        case let failure? where failure.isConnectivity:
            failure.userFacingDescription
        default:
            String(localized: "life.auditC.saveError")
        }
    }

    private func startOver(_ instrument: AuditCInstrument) {
        answers = Array(repeating: nil, count: instrument.items.count)
        answeredLocale = instrument.locale
        pending = nil
    }

    // MARK: - Removal

    func askRemoval(_ id: String) {
        removeError = nil
        confirmingRemovalID = id
    }

    func remove(_ id: String, store: LifeCircumstancesStore) async {
        guard removingID == nil else { return }
        removingID = id
        removeError = nil
        defer { removingID = nil }
        do {
            try await store.removeAuditC(id: id)
            confirmingRemovalID = nil
            Self.announce(String(localized: "life.auditC.removed"))
        } catch {
            if case .server(404, _, _)? = error as? HLError {
                // Already gone (another device); the reload shows it.
                confirmingRemovalID = nil
                return
            }
            removeError = String(localized: "life.auditC.removeError")
        }
    }

    // MARK: - The earlier one-word answer (POLISH-C, C7)

    /// The removal of the earlier answer is being asked about, in place.
    var isConfirmingLegacyRemoval = false
    private(set) var isRemovingLegacy = false
    private(set) var legacyRemoveError: String?

    func askLegacyRemoval() {
        legacyRemoveError = nil
        isConfirmingLegacyRemoval = true
    }

    func removeLegacy(store: LifeCircumstancesStore) async {
        guard !isRemovingLegacy else { return }
        isRemovingLegacy = true
        legacyRemoveError = nil
        defer { isRemovingLegacy = false }
        do {
            try await store.removeLegacyAlcohol()
            isConfirmingLegacyRemoval = false
            Self.announce(String(localized: "life.auditC.legacy.removed"))
        } catch {
            if store.legacyAlcohol == nil {
                // Already gone (another device); the reload shows it.
                isConfirmingLegacyRemoval = false
                return
            }
            legacyRemoveError = String(localized: "life.auditC.legacy.removeError")
        }
    }

    private static func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

private extension HLError {
    var isConnectivity: Bool {
        switch self {
        case .network, .offline: true
        default: false
        }
    }
}
