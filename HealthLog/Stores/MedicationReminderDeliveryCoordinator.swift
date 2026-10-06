import Foundation

/// **N1 — keeps `notificationPrefs.medication.clientManaged` true to this device.**
///
/// Inputs, all already produced elsewhere:
/// - the account's server state, off the `/api/auth/me` read the settings
///   hydration makes anyway (``SettingsStore/onMedicationReminderServerDelivery``),
///   tagged with the lease it was read under;
/// - the medication list after every load or edit (the same snapshot the local
///   planner reconciles from), tagged with the account it belongs to;
/// - the notification permission, read when an evaluation runs.
///
/// Output: at most one `PATCH /api/auth/me/notification-prefs`, and only when
/// ``MedicationReminderDeliveryPolicy`` says the server's value is wrong for
/// this device. A launch where nothing changed writes nothing; there is no
/// request of its own on the start path, and nothing runs on the main thread
/// but the bookkeeping.
///
/// **Account boundary.** Every effect is fenced by the lease of the `/me` read:
/// checked before the permission read returns into a decision, before the
/// write and after it. A medication list that belongs to another account than
/// the lease is ignored. The claim marker is keyed to the owner id.
/// ``releaseForSignOut(ownerID:)`` is the one deliberate write after the lease
/// was invalidated: user sign-out calls it between invalidation and the refresh
/// token revoke, for the owner whose credentials are still in the keychain.
@MainActor
final class MedicationReminderDeliveryCoordinator {
    typealias AuthorizationProbe = @Sendable () async -> Bool
    typealias ClaimWriter = @Sendable (_ clientManaged: Bool) async throws -> MedicationReminderServerDelivery?
    typealias SignOutRelease = @Sendable () async throws -> Void

    private struct ServerReading {
        let state: MedicationReminderServerDelivery?
        let lease: AuthenticatedSessionLease
    }

    private struct MedicationsReading {
        let ownerID: String
        let medications: [Medication]
    }

    private let marker: MedicationReminderClaimMarker
    private let notificationsAuthorized: AuthorizationProbe
    private let writeClaim: ClaimWriter
    private let releaseOnSignOut: SignOutRelease

    private var server: ServerReading?
    private var medications: MedicationsReading?
    private var evaluation: Task<Void, Never>?
    private var needsAnotherPass = false

    init(
        defaults: UserDefaults,
        notificationsAuthorized: @escaping AuthorizationProbe,
        writeClaim: @escaping ClaimWriter,
        releaseOnSignOut: @escaping SignOutRelease
    ) {
        marker = MedicationReminderClaimMarker(defaults: defaults)
        self.notificationsAuthorized = notificationsAuthorized
        self.writeClaim = writeClaim
        self.releaseOnSignOut = releaseOnSignOut
    }

    /// The `/me` reading. `state == nil` means the server does not report the
    /// field; the coordinator then never writes.
    func noteServerDelivery(_ state: MedicationReminderServerDelivery?, lease: AuthenticatedSessionLease) {
        server = ServerReading(state: state, lease: lease)
        scheduleEvaluation()
    }

    /// The medication snapshot for `ownerID` (the keychain user at the time
    /// the list settled). `nil` owner: not attributable, ignored.
    func noteMedications(_ medications: [Medication], ownerID: String?) {
        guard let ownerID, !ownerID.isEmpty else { return }
        self.medications = MedicationsReading(ownerID: ownerID, medications: medications)
        scheduleEvaluation()
    }

    /// Waits for the evaluation in flight, if any. Test seam, and the reason
    /// the evaluation is owned rather than fire-and-forget.
    func settle() async {
        while let running = evaluation {
            await running.value
        }
    }

    /// User sign-out: if this device relied on `clientManaged` for `ownerID`,
    /// take it back before the credentials go. Best effort — the marker stays
    /// when the write fails, so the same account signing in again resolves it
    /// on its next evaluation. The in-memory readings are dropped either way.
    func releaseForSignOut(ownerID: String?) async {
        evaluation?.cancel()
        server = nil
        medications = nil
        guard let ownerID, !ownerID.isEmpty, marker.isClaimed(by: ownerID) else { return }
        do {
            try await releaseOnSignOut()
            marker.clear()
        } catch {
            HLLog.notifications.warning(
                "clientManaged release on sign-out failed; the server keeps APNs reminders off until a device resolves it. err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
            )
        }
    }

    // MARK: - Evaluation

    private func scheduleEvaluation() {
        guard evaluation == nil else {
            needsAnotherPass = true
            return
        }
        evaluation = Task { [weak self] in
            await self?.runPasses()
        }
    }

    private func runPasses() async {
        repeat {
            needsAnotherPass = false
            await evaluateOnce()
        } while needsAnotherPass && !Task.isCancelled
        evaluation = nil
        // A reading that arrived after a cancellation (sign-out, then the next
        // account) still gets its pass.
        if needsAnotherPass {
            needsAnotherPass = false
            scheduleEvaluation()
        }
    }

    private func evaluateOnce() async {
        guard let reading = server, reading.state != nil else { return }
        let lease = reading.lease
        guard lease.isCurrent else {
            server = nil
            return
        }
        guard let meds = medications, meds.ownerID == lease.ownerID else { return }
        let authorized = await notificationsAuthorized()
        // The readings may have moved while the permission was read; decide on
        // the latest ones, and only if they still belong to this lease.
        guard lease.isCurrent,
              let latest = server, latest.lease.generation == lease.generation,
              latest.lease.ownerID == lease.ownerID,
              let latestMeds = medications, latestMeds.ownerID == lease.ownerID else { return }
        let owner = lease.ownerID
        let decision = MedicationReminderDeliveryPolicy.decide(
            server: latest.state,
            deliversLocally: MedicationReminderDeliveryPolicy.deliversLocally(
                notificationsAuthorized: authorized,
                medications: latestMeds.medications
            ),
            claimedHere: marker.isClaimed(by: owner)
        )
        switch decision {
        case .none:
            return
        case .noteClaim:
            marker.claim(for: owner)
        case .dropClaim:
            marker.clear()
        case .claim, .release:
            await write(clientManaged: decision == .claim, reading: latest)
        }
    }

    private func write(clientManaged: Bool, reading: ServerReading) async {
        let lease = reading.lease
        do {
            try lease.requireCurrent()
            let echoed = try await writeClaim(clientManaged)
            try lease.requireCurrent()
            let resolved = echoed ?? MedicationReminderServerDelivery(
                clientManaged: clientManaged,
                deliveryDefault: reading.state?.deliveryDefault
            )
            server = ServerReading(state: resolved, lease: lease)
            if clientManaged {
                marker.claim(for: lease.ownerID)
            } else {
                marker.clear()
            }
        } catch is CancellationError {
            return
        } catch {
            // No retry loop: the next medication load or `/me` read evaluates
            // again, and the server state it carries decides afresh.
            HLLog.notifications.warning(
                "clientManaged write failed target=\(clientManaged, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
            )
        }
    }
}
