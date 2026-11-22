import Foundation

/// The two HealthKit upload flags of the one
/// `features` reader (``ServerFeatures``), as the set
/// ``KnownServerVersion`` keeps next to the server version. The statistics
/// coordinator and ``SyncTriggerContext`` read them there, gated on the
/// version as well.
extension ServerFeatures {
    /// The set ``KnownServerVersion/recordFeatures(_:defaults:)`` keeps. A
    /// `nil` block (an older server) is the empty set.
    static func recorded(_ features: ServerFeatures?) -> Set<KnownServerVersion.Feature> {
        guard let features else { return [] }
        var set: Set<KnownServerVersion.Feature> = []
        if features.cumulativeHourBuckets { set.insert(.cumulativeHourBuckets) }
        if features.syncTriggerBackfill { set.insert(.syncTriggerBackfill) }
        if features.appleHealthSymptoms { set.insert(.appleHealthSymptoms) }
        if features.appleHealthDeletes { set.insert(.appleHealthDeletes) }
        if features.nutrientMacros { set.insert(.nutrientMacros) }
        return set
    }
}
