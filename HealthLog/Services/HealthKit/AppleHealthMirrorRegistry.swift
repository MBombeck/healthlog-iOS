import Foundation

/// **GH #47 — per-user persistence for the Apple Health medication mirror.**
///
/// Holds the mapping the importer builds each sweep: the HK
/// `medicationConceptIdentifier` → the server medication id it mirrored to, plus
/// the dose-import cursor (the instant of the last imported dose).
///
/// **CU-10 / server v1.32.25.** `GET /api/medications` now echoes
/// `externalSource`, so the mirrored-vs-native question is answered
/// server-truthfully by ``Medication/isAppleHealthMirrored``. This registry is no
/// longer that authority — it is the concept → server-id routing table the dose
/// import needs (HealthKit knows concepts, the server knows medication ids) and
/// the skip-list that stops the importer re-posting a known concept every sweep.
///
/// Partitioned by user id (like the HK anchors) so a different user on the same
/// device never inherits the previous user's mirror map. Backed by
/// `UserDefaults` (non-sensitive routing metadata, battery rationale — same as
/// the HK anchors). `Sendable`: stores only the Sendable suite provider + the
/// partition token, never a `UserDefaults` instance.
public struct AppleHealthMirrorRegistry: Sendable {
    private let defaultsProvider: @Sendable () -> UserDefaults
    private let partitionToken: String

    private var defaults: UserDefaults {
        defaultsProvider()
    }

    private var conceptMapKey: String {
        "hl.medications.appleHealth.conceptMap." + partitionToken
    }

    private var cursorKey: String {
        "hl.medications.appleHealth.doseCursor." + partitionToken
    }

    /// Stamp of the ``AppleHealthConceptKey/schemaVersion`` the persisted concept
    /// map was written under. Absent (0) for every map written before CU-10.
    private var schemaKey: String {
        "hl.medications.appleHealth.conceptKeySchema." + partitionToken
    }

    public init(
        userID: String?,
        defaultsProvider: @escaping @Sendable () -> UserDefaults = { .standard }
    ) {
        self.defaultsProvider = defaultsProvider
        partitionToken = HealthKitBackfillWindowStore.partitionToken(for: userID)
        // Run on construction so no read path can observe the poisoned map: the
        // registry is a value type rebuilt per use, and after the first migration
        // this costs one `UserDefaults` integer read.
        migrateConceptMapIfNeeded()
    }

    // MARK: - Schema migration (CU-10)

    /// Drop concept-map entries that were written under an older key scheme.
    ///
    /// Before CU-10 the keys were `String(describing: HKHealthConceptIdentifier)`
    /// — `<HKHealthConceptIdentifier: 0x12568db80>`, a memory address that never
    /// recurs. Every such entry is permanently unreachable dead weight pointing
    /// at a phantom server row, so the upgrade discards it and lets the next
    /// sweep rebuild the map under the stable SHA-256 scheme.
    ///
    /// The dose cursor is reset alongside a non-empty discard: the doses that
    /// were held back (`dosesHeldBackNotMirrored`) because their concept never
    /// resolved must be re-read, and the re-import is idempotent server-side on
    /// the dose-event UUID.
    ///
    /// - Returns: how many entries were discarded.
    @discardableResult
    func migrateConceptMapIfNeeded() -> Int {
        let storedSchema = defaults.integer(forKey: schemaKey)
        guard storedSchema < AppleHealthConceptKey.schemaVersion else { return 0 }

        let existing = defaults.dictionary(forKey: conceptMapKey) as? [String: String] ?? [:]
        let survivors = existing.filter { AppleHealthConceptKey.isDerivedKey($0.key) }
        let discarded = existing.count - survivors.count

        if survivors.isEmpty {
            defaults.removeObject(forKey: conceptMapKey)
        } else {
            defaults.set(survivors, forKey: conceptMapKey)
        }
        if discarded > 0 {
            defaults.removeObject(forKey: cursorKey)
            HLLog.healthKit.info(
                "APPLE-MED registry migrated — discarded \(discarded, privacy: .public) legacy concept keys"
            )
        }
        defaults.set(AppleHealthConceptKey.schemaVersion, forKey: schemaKey)
        return discarded
    }

    // MARK: - Concept → server-med-id map

    /// The persisted `conceptIdentifier → serverMedicationId` map.
    public func conceptMap() -> [String: String] {
        defaults.dictionary(forKey: conceptMapKey) as? [String: String] ?? [:]
    }

    /// Record that a HK concept mirrored to a server medication id (merged into
    /// the existing map so a partial sweep never drops known mappings).
    public func recordMirror(conceptIdentifier: String, medicationId: String) {
        var map = conceptMap()
        map[conceptIdentifier] = medicationId
        defaults.set(map, forKey: conceptMapKey)
    }

    /// The server medication ids currently known to be Apple-mirrored.
    ///
    /// A local hint only. Since server v1.32.25 the authoritative answer is
    /// ``Medication/isAppleHealthMirrored`` off the `externalSource` the
    /// medications GET echoes.
    public func mirroredMedicationIDs() -> Set<String> {
        Set(conceptMap().values)
    }

    /// **CU-10 — fold server truth into the routing table.**
    ///
    /// Called once per sweep with what `GET /api/medications` actually returned:
    /// `serverMirrors` maps `externalId → medicationId` for every row the server
    /// itself flags `externalSource == APPLE_HEALTH`, and `knownMedicationIDs` is
    /// every medication id the account holds.
    ///
    /// Two effects: a mapping whose medication was deleted server-side is dropped
    /// (so the concept is posted again rather than routing doses into a hole), and
    /// a mirror the server knows about but this device does not is adopted
    /// WITHOUT a create call. Only ever called when the GET succeeded — a failed
    /// read must not be read as "the server holds nothing".
    ///
    /// Server rows whose `externalId` is itself pointer-shaped are ignored: those
    /// are the phantom rows the defect minted, and no concept will ever hash back
    /// to them. They are the server's to clean up, not routing table entries.
    public func reconcile(serverMirrors: [String: String], knownMedicationIDs: Set<String>) {
        var map = conceptMap().filter { knownMedicationIDs.contains($0.value) }
        for (externalId, medicationId) in serverMirrors
            where AppleHealthConceptKey.isDerivedKey(externalId)
        {
            map[externalId] = medicationId
        }
        if map.isEmpty {
            defaults.removeObject(forKey: conceptMapKey)
        } else {
            defaults.set(map, forKey: conceptMapKey)
        }
    }

    /// Resolve a HK concept to its mirrored server medication id (nil = not yet
    /// mirrored — an Apple dose for it must NOT be imported until it is).
    public func medicationId(forConcept concept: String) -> String? {
        conceptMap()[concept]
    }

    // MARK: - Dose-import cursor (legacy — read-only since plan 07-05)

    /// The instant of the last imported dose under the **pre-Phase-07** rule.
    ///
    /// **Nothing writes this value any more.** Plan 07-05 replaced the single
    /// `Date` watermark with ``AppleHealthDoseLedger``, because a watermark
    /// cannot express "everything up to here landed except these three": a dose
    /// held back for a not-yet-mirrored concept vanished behind the next
    /// success, and a strict `>` read dropped an equal-timestamp sibling.
    ///
    /// The value survives for two reasons and is read for exactly one: the
    /// ledger folds it in once as its initial horizon, and if this plan is ever
    /// rolled back the old importer resumes from the same instant it stopped at.
    /// It is frozen at whatever the last watermark sweep left behind.
    public func doseCursor() -> Date? {
        let raw = defaults.double(forKey: cursorKey)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    // MARK: - Reset (logout / user-change)

    /// Clear the mirror map + legacy cursor for this partition. Called on logout
    /// so the next user starts clean (mirrors the mood-importer anchor reset).
    ///
    /// The Phase-07 dose ledger is deliberately **not** cleared here. It is keyed
    /// `{owner, appleMedication, HKMedicationDoseEvent}` and hashes the owner
    /// into its storage key, so no other account can read it — and this method
    /// runs during the logout cascade, where re-resolving a user id is the exact
    /// M4 race the mood importer's cached partition key exists to avoid.
    /// Deleting a partition on a *guessed* owner is a worse failure than keeping
    /// an unreachable one.
    public func reset() {
        defaults.removeObject(forKey: conceptMapKey)
        defaults.removeObject(forKey: cursorKey)
    }
}
