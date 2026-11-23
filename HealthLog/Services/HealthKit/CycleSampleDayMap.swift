import Foundation

/// Which cycle day each imported Apple Health sample belongs to (#181).
///
/// The cycle import folds every foreign reproductive sample of a day into one
/// day-log under `cycle-hk:<day>`. A deletion in Apple Health hands back only
/// the sample's UUID: the object is gone, and with it its date and its type.
/// This map is what turns that UUID back into a day and a type, and it also
/// says whether the day still has another sample. A day left with none is
/// deleted on the server (`DELETE /api/cycle/day-logs/by-external-ids`). A
/// day that keeps a sample keeps its row, but the fields the deleted sample's
/// type wrote are rebuilt from what Health still holds for that day
/// (``pendingCorrections``): the server's upsert merges and never clears a
/// field it is not sent, so without this the deleted value stayed.
///
/// **Update path.** A 1.6 installation has no map, and its anchors are past
/// the samples it imported. Before the first deletion can be judged, the
/// importer seeds the map once from a plain read of every cycle type, local
/// only, no request. Until the seed exists no deletion is sent, because a day
/// whose other samples are unknown cannot be judged; the deleted UUIDs wait in
/// ``pendingDeleted`` instead of being lost with the moving anchor. A map
/// written before the types were kept reads with none: a deleted sample of an
/// unknown type rebuilds every field of its day (``allTypes``).
///
/// Dates, UUIDs and type identifiers only, no value. One file per account
/// partition in Application Support, so the launch-time defaults stay small.
struct CycleSampleDayMap: Codable, Sendable, Equatable {
    static let formatVersion = 1
    /// Stands for "every cycle type" in ``pendingCorrections``.
    static let allTypes = "*"
    /// Deleted UUIDs kept while the map is not seeded; older ones drop first.
    static let maxPendingDeleted = 5000

    var version: Int = Self.formatVersion
    /// `true` once every cycle type was read in full into the map.
    var seeded: Bool = false
    /// Sample UUID to day key (`YYYY-MM-DD`).
    var dayBySample: [String: String] = [:]
    /// Sample UUID to its HealthKit type identifier.
    var typeBySample: [String: String] = [:]
    /// Deleted UUIDs HealthKit reported before the map could judge them.
    var pendingDeleted: [String] = []
    /// Day key to the type identifiers whose fields must be rebuilt there,
    /// until the server took the correction.
    var pendingCorrections: [String: Set<String>] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        dayBySample = try c.decodeIfPresent([String: String].self, forKey: .dayBySample) ?? [:]
        typeBySample = try c.decodeIfPresent([String: String].self, forKey: .typeBySample) ?? [:]
        pendingDeleted = try c.decodeIfPresent([String].self, forKey: .pendingDeleted) ?? []
        pendingCorrections = try c.decodeIfPresent([String: Set<String>].self, forKey: .pendingCorrections) ?? [:]
    }

    /// Records `pairs` (sample UUID, day key) of type `identifier`. A later
    /// day for the same UUID wins; HealthKit never moves a sample, but a
    /// re-read in another zone may.
    mutating func record(_ pairs: [(sample: String, day: String)], identifier: String? = nil) {
        for pair in pairs where !pair.sample.isEmpty && !pair.day.isEmpty {
            dayBySample[pair.sample] = pair.day
            if let identifier { typeBySample[pair.sample] = identifier }
        }
    }

    /// Keeps deleted UUIDs for the moment the map is seeded.
    mutating func park(_ sampleIDs: [String]) {
        var known = Set(pendingDeleted)
        pendingDeleted += sampleIDs.filter { known.insert($0).inserted }
        if pendingDeleted.count > Self.maxPendingDeleted {
            pendingDeleted.removeFirst(pendingDeleted.count - Self.maxPendingDeleted)
        }
    }

    /// Takes the deleted samples (and the parked ones) out and returns the
    /// day-log external ids of the days that are left without any sample,
    /// sorted. A day that keeps a sample gets the deleted samples' types in
    /// ``pendingCorrections``. Unknown UUIDs (a sample this app never
    /// imported, or an own write) change nothing.
    mutating func removeDeleted(_ sampleIDs: [String]) -> [String] {
        var touched: [String: Set<String>] = [:]
        for id in pendingDeleted + sampleIDs {
            guard let day = dayBySample.removeValue(forKey: id) else { continue }
            touched[day, default: []].insert(typeBySample.removeValue(forKey: id) ?? Self.allTypes)
        }
        pendingDeleted = []
        guard !touched.isEmpty else { return [] }
        let remaining = Set(dayBySample.values)
        var emptied: [String] = []
        for (day, types) in touched {
            if remaining.contains(day) {
                pendingCorrections[day, default: []].formUnion(types)
            } else {
                emptied.append(day)
                pendingCorrections[day] = nil
            }
        }
        return emptied.sorted().map(Self.externalID(forDay:))
    }

    static func externalID(forDay day: String) -> String {
        "cycle-hk:\(day)"
    }
}

/// Where the map lives. A directory per installation, a file per partition.
struct CycleSampleDayStore: Sendable {
    let directory: URL

    /// `Application Support/HealthLog/cycle-sample-days`.
    static var standard: CycleSampleDayStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CycleSampleDayStore(directory: base.appendingPathComponent("HealthLog/cycle-sample-days", isDirectory: true))
    }

    private func url(for partitionToken: String) -> URL {
        let safe = partitionToken.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent((safe.isEmpty ? "anonymous" : safe) + ".json")
    }

    /// The stored map, or an empty, unseeded one. An unreadable file reads as
    /// unseeded, which costs a local re-seed, never a wrong deletion.
    func load(partitionToken: String) -> CycleSampleDayMap {
        guard let data = try? Data(contentsOf: url(for: partitionToken)),
              let map = try? JSONDecoder().decode(CycleSampleDayMap.self, from: data),
              map.version == CycleSampleDayMap.formatVersion else { return CycleSampleDayMap() }
        return map
    }

    /// `false` when the write failed; the caller then sends no deletion.
    @discardableResult
    func save(_ map: CycleSampleDayMap, partitionToken: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = url(for: partitionToken)
            try JSONEncoder().encode(map).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    func remove(partitionToken: String) {
        try? FileManager.default.removeItem(at: url(for: partitionToken))
    }
}
