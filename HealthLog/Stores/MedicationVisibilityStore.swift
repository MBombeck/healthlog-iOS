import Foundation
import Observation

/// Which active medications this iPhone leaves out of the Medications tab list.
///
/// Hiding is a display choice and nothing else: the medication stays active,
/// reminders, the watch, widgets and the server see it exactly as before
/// (`MedicationsStore.activeMedications` is untouched). Only medication ids are
/// stored, in `UserDefaults`, one key per account, so a second account on the
/// same device never sees the first one's choice and a sign-out followed by a
/// sign-in to the same account finds it again.
///
/// Only explicit actions remove an id: showing the medication again, archiving
/// it and restoring it. An empty or not yet loaded medication list never
/// prunes the selection.
@MainActor
@Observable
public final class MedicationVisibilityStore {
    static let keyPrefix = "hl.medications.hiddenIDs."

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ownerIDProvider: @MainActor () -> String?
    /// The account the selection was last resolved for. Kept so an account
    /// deletion, which wipes the keychain before the cascade runs, still
    /// finds the partition it has to remove.
    @ObservationIgnored private var ownerToken: String?
    /// The selection lives in `UserDefaults`; this counter is what views
    /// observe, bumped on every change.
    private var revision = 0

    public init(
        defaults: UserDefaults = .standard,
        ownerIDProvider: @escaping @MainActor () -> String?
    ) {
        self.defaults = defaults
        self.ownerIDProvider = ownerIDProvider
    }

    /// Ids of the medications hidden on this device for the signed-in account.
    public var hiddenIDs: Set<String> {
        _ = revision
        guard let key = currentKey() else { return [] }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func isHidden(_ id: String) -> Bool {
        hiddenIDs.contains(id)
    }

    public func hide(_ id: String) {
        update { $0.insert(id) }
    }

    /// Show the medication again. Also called when it is archived or
    /// restored, so an archived medication only ever stands under „Archiviert“.
    public func unhide(_ id: String) {
        update { $0.remove(id) }
    }

    /// Hide and offer the shared undo toast, naming the medication.
    public func hide(_ medication: Medication, undo: UndoCoordinator?) {
        hide(medication.id)
        let id = medication.id
        undo?.enqueue(message: String(localized: "medications.hidden.undo \(medication.name)")) { [weak self] in
            await self?.unhide(id)
        }
    }

    /// Drop this account's selection from disk. Used by „Daten zurücksetzen“
    /// and by the account deletion; when no account can be resolved any more,
    /// every partition goes, because a stale one could not be reached anyway.
    public func wipeSelection() {
        if let key = currentKey() {
            defaults.removeObject(forKey: key)
        } else {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        revision &+= 1
    }

    // MARK: - Internals

    private func update(_ change: (inout Set<String>) -> Void) {
        guard let key = currentKey() else { return }
        var ids = Set(defaults.stringArray(forKey: key) ?? [])
        let before = ids
        change(&ids)
        guard ids != before else { return }
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.sorted(), forKey: key)
        }
        revision &+= 1
    }

    private func currentKey() -> String? {
        if ownerToken == nil, let owner = ownerIDProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty
        {
            ownerToken = MeasurementsStore.backfillPartitionToken(for: owner)
        }
        return ownerToken.map { Self.keyPrefix + $0 }
    }
}

// MARK: - Logout

public extension MedicationVisibilityStore {
    /// The selection itself stays: it is keyed to the account, holds ids and no
    /// names, and the next account reads its own key. Only the resolved account
    /// is forgotten, so the next sign-in resolves afresh.
    func clearOnLogout() {
        ownerToken = nil
        revision &+= 1
    }
}
