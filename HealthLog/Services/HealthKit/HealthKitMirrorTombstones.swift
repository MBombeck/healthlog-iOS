import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// **S1 / public #11** — server ids whose Apple-Health sample the user
    /// deleted, so the server→Health mirror does not write them back.
    ///
    /// Deleting a HealthLog-written sample in Apple Health does not delete the
    /// server row unless that row came from Apple Health
    /// (`DELETE /api/measurements/by-external-ids` is scoped to
    /// `APPLE_HEALTH`). A WITHINGS, IMPORT or MANUAL row therefore survives,
    /// and without this list the next refresh would mirror it straight back.
    /// Recorded from the deletion path, read by the mirror.
    ///
    /// Server ids are globally unique, so the list needs no per-user partition.
    /// It keeps the newest ``capacity`` ids. Ids carry no health data.
    struct HealthKitMirrorTombstones: @unchecked Sendable {
        static let defaultsKey = "hl.healthkit.serverMirror.tombstones.v1"
        static let capacity = 2000

        /// `UserDefaults` is thread-safe; the box is only `@unchecked` because
        /// the type itself is not declared `Sendable`.
        private let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
        }

        var ids: Set<String> {
            Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        }

        func record(_ newIDs: [String]) {
            let additions = newIDs.filter { !$0.isEmpty }
            guard !additions.isEmpty else { return }
            var stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
            stored.removeAll { additions.contains($0) }
            stored.append(contentsOf: additions)
            if stored.count > Self.capacity {
                stored.removeFirst(stored.count - Self.capacity)
            }
            defaults.set(stored, forKey: Self.defaultsKey)
        }

        /// The server ids of the deletions this app can prove it minted (the
        /// same two-signal check the delete-propagation path uses).
        static func mintedIDs(fromDeletedMetadata metadata: [[String: Any]?]) -> [String] {
            metadata.compactMap { entry in
                guard HealthKitSampleOwnership.isAppMintedDeletion(metadata: entry) else { return nil }
                return entry?[HKMetadataKeyExternalUUID] as? String
            }
        }
    }

#endif
