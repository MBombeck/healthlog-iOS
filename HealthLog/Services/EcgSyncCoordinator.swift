import Foundation

/// Platform-agnostic seam for the ECG upload path (GH #74, server v1.35.3), so
/// `AppContainer` can hold an `EcgSyncing?` slot and the wake paths can call
/// one method. Mirrors ``NutrientDailySyncing``.
public protocol EcgSyncing: AnyObject, Sendable {
    /// Upload every ECG recording HealthKit has not handed us yet.
    /// Fire-and-forget: the coordinator self-gates on the device-local opt-in,
    /// the `insights` module and a present auth token, so it is safe to call
    /// unconditionally from a wake path.
    func triggerEcgSync() async
}

/// Uploads Apple-Watch ECG recordings to `POST /api/insights/ecg`
/// (GH #74, server v1.35.3).
///
/// ## What it does
///
/// One anchored pass over HealthKit's `HKElectrocardiogram` samples: read the
/// metadata of everything new, then for each recording in turn read its trace,
/// convert it to integer microvolts, POST it as a single request, and drop it.
/// One recording per request — the route takes no batch — and **one waveform in
/// memory at a time**, which is the whole reason the source seam separates
/// metadata from voltages.
///
/// ## Gates (three, all fail-closed)
///
/// 1. **Device-local opt-in.** The ECG read type is deliberately kept out of the
///    onboarding sheet; nothing runs until the user turns the switch on
///    (``EcgHealthSyncStore``). Without it we would neither hold the permission
///    nor be entitled to it.
/// 2. **Auth token.** No session, nothing to upload to.
/// 3. **`insights` module.** The same module that gates the ECG *reads*. If the
///    server disables it mid-flight the route answers `403`, ``APIClient``
///    mirrors the key into ``ModuleGate``, and the sweep stops.
///
/// ## Which recordings, and how often
///
/// An `HKAnchoredObjectQuery` anchor, persisted per user in `UserDefaults`
/// (battery rationale — PROJECT_GUIDE.md), exactly like the workout and heart-event
/// importers. The anchor is **insertion-ordered**, not date-ordered: a strip
/// recorded on holiday and only synced off the watch two weeks later still
/// arrives as new, which a `recordedAt` cursor would silently skip. There is no
/// observer query and no full re-scan per wake — a full scan for a datum that
/// appears a few times a year would be pure waste; the sweep rides the wake
/// paths that already exist.
///
/// **Empty and denied reads look identical**, because HealthKit refuses to say
/// whether read permission was granted: a denied type answers exactly like an
/// empty one. Therefore an empty sweep does **not** persist its anchor — only an
/// `inserted`, `updated`, or `duplicate` result is allowed to advance it. This
/// keeps delivery fail-closed if authorization or store visibility changes.
///
/// **Restore from backup.** `UserDefaults` and HealthKit both come back, so in
/// the good case the cursor resumes where it was. If the restored anchor no
/// longer matches the restored store, HealthKit answers with everything, and
/// every recording is re-sent — where each one lands as `duplicate` (200) and
/// writes nothing, because `HKSample.uuid` survives the restore and the
/// server's second unique index on `(userId, source, recordedAt,
/// samplingFrequency)` catches even the case where it does not. The worst
/// outcome of a restore is therefore some redundant traffic, never a duplicated
/// or lost recording. That is precisely what the server built the second index
/// for.
///
/// ## Errors are four different things
///
/// - **Success** — `inserted` / `updated` / `duplicate`, all three.
/// - **Rejected/unreadable** (`4xx` that is neither gate nor rate limit; an
///   unreadable or over-long trace) — count it and carry on with the remainder,
///   but retain the shared anchor. A fixed/recovered candidate must be able to
///   retry it; only a released success consumes a recording.
/// - **Gated** (`403`) / **unauthenticated** (`401`) — stop the sweep, hold the
///   anchor, do not retry.
/// - **Wait** (`429`) / **transport** (network, offline, 5xx) — stop the sweep,
///   hold the anchor, resume on the next wake.
///
/// **No Outbox.** The retry queue for this path is the HealthKit store itself:
/// holding the anchor makes the next wake re-read exactly the recordings that
/// did not land, and the recording's own identity makes the replay a no-op if
/// one of them actually did. Copying a decrypted 15 000-sample waveform into
/// the Outbox's SQLite file to achieve the same thing would put health data in
/// a store that outlives the request for no gain at all.
///
/// ## Nothing about the trace is ever logged
///
/// Every log line here is a count, a status word or an error class. No sample,
/// no verdict, no timestamp of a recording.
public actor EcgSyncCoordinator {
    private let source: any EcgRecordingSource
    private let repo: EcgRepository
    private let keychain: KeychainStoring
    /// Reads the device-local opt-in on the main actor, injected as a closure so
    /// the actor stays free of a `@MainActor` store reference.
    private let isOptedIn: @Sendable () async -> Bool
    /// Reads ``ModuleGate/isEnabled(_:)`` for `.insights` on the main actor.
    private let isModuleEnabled: @Sendable () async -> Bool
    /// `UserDefaults` is not `Sendable` — injected behind a provider closure
    /// (same pattern as ``NutrientDailySyncCoordinator``).
    private let defaultsProvider: @Sendable () -> UserDefaults
    /// Test seam for a failed durable cursor write. Production uses the
    /// UserDefaults write + read-back path below.
    private let anchorPersistenceOverride: (@Sendable (Data, String) -> Bool)?
    /// **Phase 07 / plan 07-06** — the Phase-06/07 account authority, when the
    /// composition root has one to give.
    ///
    /// It never *widens* this path: the sweep's owner and bearer are still
    /// captured from the Keychain before the first suspension, exactly as Phase
    /// 06 built it. What an admission adds is a second, independent authority —
    /// the session generation — so a same-owner re-login invalidates a sweep the
    /// bearer comparison alone would have let continue, and the partition this
    /// coordinator resets is named by a ``HealthSyncOwnerLease`` rather than by
    /// whoever the Keychain happens to hold when the reset finally runs.
    private let admission: HealthSyncImporterAdmission?

    /// The partition the most recent admitted sweep ran under. This — not a
    /// live Keychain read — is what `resetAnchor()` clears.
    private var capturedPartition: EcgAnchorPartition?
    /// Sweeps this coordinator owns, so a teardown can cancel and drain them
    /// instead of racing them.
    private var ownedSweeps: [UUID: Task<EcgSyncSummary, Never>] = [:]

    private var defaults: UserDefaults {
        defaultsProvider()
    }

    /// Per-user anchor key prefix.
    static let anchorKeyPrefix = "hl.ecg.hk.anchor."

    /// One account's ECG cursor identity, captured before any suspension.
    ///
    /// `ownerLease` is present once the composition root binds an admission; the
    /// storage key is identical either way, because both authorities name the
    /// same signed-in user. Keeping the lease is what makes the reset target an
    /// *admitted* account rather than a remembered string.
    struct EcgAnchorPartition: Sendable {
        let ownerUserID: String
        let storageKey: String
        let ownerLease: HealthSyncOwnerLease?

        /// `true` while this partition's account is still the live one. A
        /// coordinator with no owner lease has only the sweep's own bearer
        /// check, which the caller applies separately.
        var isCurrent: Bool {
            ownerLease?.isCurrent ?? true
        }
    }

    public init(
        source: any EcgRecordingSource,
        repo: EcgRepository,
        keychain: KeychainStoring,
        isOptedIn: @escaping @Sendable () async -> Bool,
        isModuleEnabled: @escaping @Sendable () async -> Bool,
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard },
        anchorPersistenceOverride: (@Sendable (Data, String) -> Bool)? = nil,
        admission: HealthSyncImporterAdmission? = nil
    ) {
        self.source = source
        self.repo = repo
        self.keychain = keychain
        self.isOptedIn = isOptedIn
        self.isModuleEnabled = isModuleEnabled
        self.defaultsProvider = defaultsProvider
        self.anchorPersistenceOverride = anchorPersistenceOverride
        self.admission = admission
    }

    // MARK: - Sweep

    /// Runs one sweep. Returns the tally; tests assert against the counters and
    /// the captured request payloads.
    @discardableResult
    public func sync() async -> EcgSyncSummary {
        guard await isOptedIn() else {
            HLLog.healthKit.debug("ECG sync skipped — opt-in off")
            return .zero
        }
        guard let authLease = captureAuthenticationLease() else {
            HLLog.healthKit.debug("ECG sync skipped — no auth token")
            return .zero
        }
        guard await isModuleEnabled() else {
            HLLog.healthKit.debug("ECG sync skipped — insights module OFF")
            return .zero
        }
        guard authLease.isCurrent else {
            return EcgSyncSummary(stoppedBecause: .transport)
        }
        // The partition is captured here, before the first suspension, and it is
        // what a later teardown clears. An admitted owner lease, when the
        // composition root bound one, must agree with the bearer capture: two
        // authorities naming two different accounts is precisely the A→B window,
        // and the honest answer is to run nothing.
        guard let partition = capturePartition(for: authLease) else {
            return EcgSyncSummary(stoppedBecause: .unauthorized)
        }
        capturedPartition = partition
        let storedAnchor = defaults.data(forKey: partition.storageKey)

        let fetched: EcgSourceFetchResult
        do {
            fetched = try await source.fetchRecordings(since: storedAnchor)
        } catch {
            HLLog.healthKit.error(
                "ECG metadata fetch failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return EcgSyncSummary(stoppedBecause: .transport)
        }
        guard authLease.isCurrent, partition.isCurrent else {
            return EcgSyncSummary(stoppedBecause: .transport)
        }

        let (summary, retainAnchor) = await uploadRecordings(
            fetched.recordings,
            requiring: authLease,
            within: partition
        )

        return advanceAnchorIfEarned(
            summary: summary,
            retainAnchor: retainAnchor,
            fetched: fetched,
            storedAnchor: storedAnchor,
            requiring: authLease,
            within: partition
        )
    }

    /// The tail of a sweep: decide whether this pass earned the fetched anchor,
    /// and write it into the captured partition if it did.
    ///
    /// Split out of ``sync()`` so the cursor decision is one readable rule rather
    /// than the fifth branch of a long method. Only the three released success
    /// statuses consume the fetched anchor; every validation, waveform, auth,
    /// rate-limit, transport, cancellation or persistence failure leaves
    /// HealthKit itself as the retry queue.
    private func advanceAnchorIfEarned(
        summary: EcgSyncSummary,
        retainAnchor: Bool,
        fetched: EcgSourceFetchResult,
        storedAnchor: Data?,
        requiring authLease: EcgUploadAuthenticationLease,
        within partition: EcgAnchorPartition
    ) -> EcgSyncSummary {
        var summary = summary
        if retainAnchor || Task.isCancelled {
            if Task.isCancelled, summary.stoppedBecause == nil {
                summary.stoppedBecause = .transport
            }
            return summary
        }
        guard !Self.shouldSkipAnchorSave(
            hadPersistedAnchor: storedAnchor != nil,
            fetchedCount: fetched.recordings.count
        ) else {
            HLLog.healthKit.debug("ECG sweep empty — anchor NOT advanced (read auth pending or no visible history)")
            return summary
        }
        guard let anchor = fetched.anchor else { return summary }
        guard authLease.isCurrent, partition.isCurrent else {
            summary.stoppedBecause = .transport
            return summary
        }
        guard persistAnchor(anchor, replacing: storedAnchor, forKey: partition.storageKey) else {
            summary.stoppedBecause = .persistence
            return summary
        }
        return summary
    }

    /// **Do not advance the cursor on an empty sweep.** HealthKit does not reveal
    /// whether an empty result means no recordings or denied read access. More
    /// importantly, the released contract only lets `inserted`, `updated`, or
    /// `duplicate` consume the fetched anchor. Retaining an established cursor
    /// on an empty result trades a cheap repeated query for fail-closed delivery.
    /// Pure + static so the policy is testable without HealthKit.
    static func shouldSkipAnchorSave(hadPersistedAnchor _: Bool, fetchedCount: Int) -> Bool {
        fetchedCount == 0
    }

    /// Clear the per-user cursor (logout / user change / opt-out), so the next
    /// user never inherits this one's position in the ECG stream.
    ///
    /// **Phase 07 / plan 07-06 — the owner is captured, then the work is drained,
    /// then the partition is cleared.** In that order, and the order is the fix.
    ///
    /// The shipped version chose its key from a live Keychain read at the moment
    /// the reset ran. Every caller reaches it from inside the logout cascade —
    /// which wipes the Keychain user id and dispatches the HealthKit cleanup
    /// separately — so the read could observe a half-wiped id and clear the
    /// `_anonymous` partition, stranding the account's real cursor; and if a
    /// replacement account had already signed in, it cleared *that* account's
    /// cursor instead. Both are mutations of a partition this reset never owned.
    ///
    /// Now the key comes from the partition the last admitted sweep ran under
    /// (falling back to one Keychain read taken *here*, before any suspension,
    /// when this process never swept). In-flight owned sweeps are cancelled and
    /// awaited before the removal, so nothing can re-write the key afterwards,
    /// and an A→B switch that lands during the drain cannot redirect the removal
    /// onto B — the key was decided before the drain began.
    public func resetAnchor() async {
        let key = capturedPartition?.storageKey ?? anchorKey()
        let draining = ownedSweeps
        ownedSweeps.removeAll()
        for task in draining.values {
            task.cancel()
        }
        for task in draining.values {
            _ = await task.value
        }
        defaults.removeObject(forKey: key)
        capturedPartition = nil
    }

    /// Names the account this sweep belongs to, before the first suspension.
    ///
    /// Returns `nil` only when an admission is bound and refuses to agree with
    /// the bearer capture — a disagreement between the two authorities is an
    /// account boundary in progress, and running under either guess is the exact
    /// harm this phase closes.
    private func capturePartition(for authLease: EcgUploadAuthenticationLease) -> EcgAnchorPartition? {
        guard let admission else {
            return EcgAnchorPartition(
                ownerUserID: authLease.ownerUserID,
                storageKey: anchorKey(for: authLease.ownerUserID),
                ownerLease: nil
            )
        }
        guard let lease = try? admission.provider(for: .ecg)() else {
            // No admitted session (the composition has not activated one yet).
            // The bearer capture still stands on its own, so the sweep proceeds
            // under it rather than silently stopping ECG delivery.
            return EcgAnchorPartition(
                ownerUserID: authLease.ownerUserID,
                storageKey: anchorKey(for: authLease.ownerUserID),
                ownerLease: nil
            )
        }
        let owner: HealthSyncOwnerLease = lease.owner
        guard owner.ownerID == authLease.ownerUserID else {
            HLLog.healthKit.error("ECG sync refused — the admitted account is not the one this sweep captured")
            return nil
        }
        return EcgAnchorPartition(
            ownerUserID: owner.ownerID,
            storageKey: anchorKey(for: owner.ownerID),
            ownerLease: owner
        )
    }

    // MARK: - One recording

    /// Internal (not `private`) so the error-classification test can assert the
    /// four classes directly, without a network round-trip per case.
    enum RecordingOutcome: Equatable {
        case accepted(EcgIngestStatus)
        case skipped(EcgSyncSkipReason)
        case halted(EcgSyncStopReason)
    }

    private func uploadRecordings(
        _ recordings: [EcgSourceRecording],
        requiring authLease: EcgUploadAuthenticationLease,
        within partition: EcgAnchorPartition
    ) async -> (EcgSyncSummary, Bool) {
        var summary = EcgSyncSummary.zero
        var retainAnchor = false
        for recording in recordings {
            if !authLease.isCurrent || !partition.isCurrent {
                summary.stoppedBecause = .transport
                return (summary, true)
            }
            switch await upload(recording, requiring: authLease) {
            case let .accepted(status):
                summary.record(status)
            case let .skipped(reason):
                summary.skip(reason)
                retainAnchor = true
            case let .halted(reason):
                summary.stoppedBecause = reason
                return (summary, true)
            }
        }
        return (summary, retainAnchor)
    }

    private func persistAnchor(_ anchor: Data, replacing previous: Data?, forKey key: String) -> Bool {
        let persisted: Bool
        if let anchorPersistenceOverride {
            persisted = anchorPersistenceOverride(anchor, key)
        } else {
            defaults.set(anchor, forKey: key)
            persisted = defaults.data(forKey: key) == anchor
        }
        guard !persisted else { return true }
        if let previous {
            defaults.set(previous, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return false
    }

    /// Read one trace, convert it, send it, drop it.
    private func upload(
        _ recording: EcgSourceRecording,
        requiring authLease: EcgUploadAuthenticationLease
    ) async -> RecordingOutcome {
        // The ceiling is checked against METADATA, so an over-long recording
        // never costs the memory of its own waveform. Skipped, never truncated.
        guard recording.sampleCount <= EcgIngestRequestDTO.maxSamples else {
            // M-7 reviewed: two sample COUNTS. Not a value, not a verdict, not a
            // timestamp — nothing that says anything about the person or the
            // recording beyond how long it is.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info(
                "ECG recording skipped — \(recording.sampleCount, privacy: .public) samples exceeds route limit \(EcgIngestRequestDTO.maxSamples, privacy: .public)"
            )
            return .skipped(.tooManySamples)
        }

        let volts: [Double]
        do {
            volts = try await source.voltages(forRecordingID: recording.id)
        } catch {
            HLLog.healthKit.error(
                "ECG waveform read failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
            )
            return .skipped(.waveformUnavailable)
        }
        guard authLease.isCurrent else { return .halted(.transport) }

        // Re-check after the read: the metadata count is what HealthKit
        // promised, this is what it delivered.
        guard volts.count <= EcgIngestRequestDTO.maxSamples else {
            return .skipped(.tooManySamples)
        }
        guard let samples = EcgSampleScale.microvolts(fromVolts: volts) else {
            HLLog.healthKit.info("ECG recording skipped — a voltage reading is not expressible in microvolts")
            return .skipped(.unreadableSample)
        }

        let payload = EcgIngestRequestDTO(
            externalRecordingId: recording.id,
            recordedAt: recording.recordedAt,
            samplingFrequency: recording.samplingFrequency,
            samples: samples,
            lead: recording.lead,
            averageHeartRate: recording.averageHeartRate,
            classification: recording.classification
        )

        do {
            let response = try await repo.uploadRecording(payload, requiring: authLease)
            let status = response.status.rawValue
            // M-7 reviewed: the server's own status word (`inserted` / `updated`
            // / `duplicate`). Deliberately NOT the row id and NOT the recording
            // id — an operator needs to know the sweep worked, not which strip.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.healthKit.info("ECG upload \(status, privacy: .public)")
            return .accepted(response.status)
        } catch {
            return Self.disposition(for: error)
        }
    }

    /// The four error classes, named once.
    ///
    /// `nonisolated static` + pure so the classification can be tested directly
    /// alongside the end-to-end `MockURLProtocol` runs.
    nonisolated static func disposition(for error: any Error) -> RecordingOutcome {
        guard let hlError = error as? HLError else {
            // An unmapped error is not understood well enough to be called
            // permanent. Treat it as transport: hold the cursor and retry.
            return .halted(.transport)
        }
        switch hlError {
        case .moduleDisabled, .assistantDisabled:
            return .halted(.gated)
        case .unauthorized:
            return .halted(.unauthorized)
        case .rateLimited:
            return .halted(.rateLimited)
        case .network, .offline, .canceled, .serverNotConfigured:
            return .halted(.transport)
        case let .server(status, _, _):
            if status == 403 || status == 401 {
                // `insightStatus` is not a known `FeatureFlag`, so its 403
                // arrives untyped. It is still a gate, not a failure.
                return .halted(status == 401 ? .unauthorized : .gated)
            }
            if status == 429 { return .halted(.rateLimited) }
            if status >= 500 || status == 408 { return .halted(.transport) }
            // Every other 4xx — 400 / 404 / 409 / 413 and above all the 422 for
            // an unknown body field — means the request was understood and
            // refused. Replaying it would replay our own mistake.
            return .skipped(.rejectedByServer)
        case .decoding:
            // The write may well have landed; we simply could not read the
            // answer. Replaying is safe (the recording carries its identity),
            // but it is not a body problem — treat it as transport.
            return .halted(.transport)
        case .refusedWithReason, .writeConflictUnresolved, .notPersisted, .unknown:
            return .skipped(.rejectedByServer)
        }
    }

    // MARK: - Anchor key

    private func anchorKey(for userID: String?) -> String {
        Self.anchorKeyPrefix + HealthKitBackfillWindowStore.partitionToken(for: userID)
    }

    private func anchorKey() -> String {
        anchorKey(for: keychain.getString(forKey: KeychainKey.userID))
    }

    /// Capture owner and bearer before the first suspension. Equality against
    /// the live Keychain pair is the credential-generation check: logout,
    /// token replacement, and A→B→A all permanently invalidate this sweep.
    private func captureAuthenticationLease() -> EcgUploadAuthenticationLease? {
        let owner = Self.canonicalAuthenticationValue(
            keychain.getString(forKey: KeychainKey.userID)
        )
        let bearer = Self.canonicalAuthenticationValue(
            keychain.getString(forKey: KeychainKey.authToken)
        )
        guard !owner.isEmpty, !bearer.isEmpty else { return nil }
        return EcgUploadAuthenticationLease(
            ownerUserID: owner,
            bearerToken: bearer,
            isCurrent: { [keychain] in
                Self.canonicalAuthenticationValue(
                    keychain.getString(forKey: KeychainKey.userID)
                ) == owner
                    && Self.canonicalAuthenticationValue(
                        keychain.getString(forKey: KeychainKey.authToken)
                    ) == bearer
            }
        )
    }

    private nonisolated static func canonicalAuthenticationValue(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

extension EcgSyncCoordinator {
    /// Runs one sweep as work this coordinator **owns**, so a teardown can
    /// cancel and drain it rather than race it.
    ///
    /// The unregistered `sync()` remains for direct drives (the suites call it);
    /// every wake path reaches ECG through `triggerEcgSync()`, which is what
    /// makes the reset's drain a statement about production rather than a hope.
    func runOwnedSweep() async -> EcgSyncSummary {
        let id = UUID()
        let task = Task { await self.sync() }
        ownedSweeps[id] = task
        let summary = await task.value
        ownedSweeps[id] = nil
        return summary
    }
}

extension EcgSyncCoordinator: EcgSyncing {
    public func triggerEcgSync() async {
        let summary = await runOwnedSweep()
        guard summary.accepted > 0 || summary.skippedCount > 0 || summary.stoppedBecause != nil else { return }
        let inserted = summary.inserted
        let updated = summary.updated
        let duplicate = summary.duplicate
        let skipped = summary.skippedCount
        let stopped = summary.stoppedBecause?.rawValue ?? "-"
        HLLog.healthKit
            .info(
                """
                ECG sync done — inserted=\(inserted, privacy: .public) \
                updated=\(updated, privacy: .public) \
                duplicate=\(duplicate, privacy: .public) \
                skipped=\(skipped, privacy: .public) \
                stopped=\(stopped, privacy: .public)
                """
            )
    }
}
