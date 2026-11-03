#if canImport(HealthKit)
    import Foundation
    import HealthKit

    /// **A6 (1.4)** — how a HealthLog copy in Apple Health keeps naming its
    /// server row after the person deletes it there.
    ///
    /// A deleted object keeps exactly two metadata keys,
    /// `HKMetadataKeySyncIdentifier` and `HKMetadataKeySyncVersion` (Apple,
    /// `HKDeletedObject.metadata`). Our external UUID and origin marker are gone
    /// by then, which is why the tombstones of the server mirror stayed empty
    /// until 1.4. So every object HealthLog writes for a server row, at create
    /// time and from the server mirror, carries
    /// `dev.healthlog.measurement/<type>/<server id>` at version 1. A deletion
    /// then names the row directly, with no map on the device.
    ///
    /// * **The type** keeps the blood-pressure correlation and its two halves
    ///   apart. HealthKit matches identifiers within this app's source; it does
    ///   not say whether it also keeps types apart.
    /// * **HealthKit's replace rule:** a save whose identifier is already there
    ///   at the same or a lower version is ignored, a higher version replaces.
    ///   The mirror never edits a copy, so the version stays 1, and a second
    ///   save of the same row (a second device of the same person, a mirror
    ///   pass racing the create-time write) adds nothing and fails nothing.
    /// * **Copies written before 1.4** carry no identifier. Their deletion
    ///   cannot be told from the deletion of a reading another app wrote: it is
    ///   forwarded to the server like one (a no-op there, the copy was never
    ///   uploaded), no tombstone is recorded, and the mirror writes the reading
    ///   once more, this time with an identifier. Deleting that copy sticks.
    enum HealthKitCopySyncIdentity {
        static let prefix = "dev.healthlog.measurement/"
        static let version = 1

        /// The identifier of the copy of `serverID` in a sample of `typeIdentifier`.
        static func identifier(serverID: String, typeIdentifier: String) -> String {
            prefix + typeIdentifier + "/" + serverID
        }

        /// The two keys a copy carries next to its external UUID.
        static func metadata(serverID: String, typeIdentifier: String) -> [String: Any] {
            [
                HKMetadataKeySyncIdentifier: identifier(serverID: serverID, typeIdentifier: typeIdentifier),
                HKMetadataKeySyncVersion: version
            ]
        }

        /// The server id a HealthLog copy's identifier names; `nil` for anything
        /// else, an identifier another app chose included.
        static func serverID(fromSyncIdentifier value: Any?) -> String? {
            guard let value = value as? String, value.hasPrefix(prefix) else { return nil }
            let rest = value.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
            let serverID = rest[rest.index(after: slash)...]
            return serverID.isEmpty ? nil : String(serverID)
        }

        /// One page's deleted objects, as HealthKit reports them (UUID and the
        /// metadata a deletion keeps), split into the UUIDs that go to the
        /// server's delete route and the server ids of deleted HealthLog copies.
        static func split(
            _ deleted: [(uuid: UUID, metadata: [String: Any]?)]
        ) -> (sampleIDs: [String], copyServerIDs: [String]) {
            var sampleIDs: [String] = []
            var copyServerIDs: [String] = []
            for object in deleted {
                if let serverID = serverID(fromSyncIdentifier: object.metadata?[HKMetadataKeySyncIdentifier]) {
                    copyServerIDs.append(serverID)
                } else {
                    sampleIDs.append(object.uuid.uuidString)
                }
            }
            return (sampleIDs, copyServerIDs)
        }
    }
#endif
