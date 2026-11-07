import Foundation

// 1.5 FIX-DATA (#157 point 1) — deleting a blood-pressure reading takes the
// whole reading.
//
// The server stores one reading as up to three rows without a link column:
// systolic, diastolic and the cuff's pulse, with the same source and the
// identical `measuredAt`. The list merges systolic and diastolic into one row
// (`bloodPressureDiastolicId`); the pulse is a row of its own.
//
// From server 1.46.2 a `DELETE` on either half tombstones the other half and the
// pulse in one transaction, and `POST /api/measurements/restore` with one half
// brings back exactly the rows deleted with it. Before that the server deleted
// only the row it was given, so an older server gets both halves through the
// bulk delete (the pulse stays there, so it stays here too) and the undo
// re-creates the reading as before.

/// The server version from which one `DELETE` removes the whole reading and one
/// restore brings it back.
enum BloodPressureReadingDelete {
    static let minimumServerVersion = "1.46.2"
}

/// What one delete does on the wire and in the list. Decided once, when the
/// person deletes, so the undo acts on what the server was asked to do.
struct MeasurementDeletePlan {
    enum Wire: Equatable {
        /// `DELETE /api/measurements/{id}`.
        case single(String)
        /// `POST /api/measurements/bulk-delete` with these ids.
        case bulk([String])
    }

    /// The row the person deleted.
    let row: Measurement
    /// Pulse rows of the same reading that leave the list with it (only when
    /// the server deletes them too).
    let pulseRows: [Measurement]
    let wire: Wire
    /// The server deletes and restores the whole reading from one id.
    let serverTakesWholeReading: Bool

    var localIDs: Set<String> {
        Set([row.id] + pulseRows.map(\.id))
    }
}

/// Whether the delete reached the server. Read by the undo, which may fire
/// while the request is still in flight.
@MainActor
final class MeasurementDeleteOutcome {
    var landed = false
}

@MainActor
public extension MeasurementsStore {
    /// The pulse rows that belong to `reading`: same source, identical time,
    /// never an aggregate (`stats:` externalId) or a synthetic bucket. The
    /// server's rule, `src/lib/measurements/blood-pressure-reading.ts`.
    func readingPulseRows(of reading: Measurement) -> [Measurement] {
        guard reading.kind == .bloodPressure else { return [] }
        return recent.filter {
            $0.kind == .pulse
                && $0.id != reading.id
                && $0.source == reading.source
                && $0.recordedAt == reading.recordedAt
                && !$0.isSyntheticServerRow
                && !($0.externalUUID?.hasPrefix("stats:") ?? false)
        }
    }

    /// `true` when the paired server deletes and restores a whole reading from
    /// one id. Standalone mode has no server and deletes its mirror row by row.
    internal var serverTakesWholeReading: Bool {
        if isStandalone?() == true { return false }
        return KnownServerVersion.isAtLeast(
            BloodPressureReadingDelete.minimumServerVersion,
            defaults: serverVersionDefaults
        )
    }

    internal func deletePlan(for measurement: Measurement) -> MeasurementDeletePlan {
        guard measurement.kind == .bloodPressure else {
            return MeasurementDeletePlan(row: measurement, pulseRows: [], wire: .single(measurement.id), serverTakesWholeReading: false)
        }
        if serverTakesWholeReading {
            return MeasurementDeletePlan(
                row: measurement,
                pulseRows: readingPulseRows(of: measurement),
                wire: .single(measurement.id),
                serverTakesWholeReading: true
            )
        }
        guard let diastolicID = measurement.bloodPressureDiastolicId else {
            return MeasurementDeletePlan(row: measurement, pulseRows: [], wire: .single(measurement.id), serverTakesWholeReading: false)
        }
        return MeasurementDeletePlan(
            row: measurement,
            pulseRows: [],
            wire: .bulk([measurement.id, diastolicID]),
            serverTakesWholeReading: false
        )
    }

    /// Newest-first insert by `recordedAt`, replacing a stale copy.
    internal func reinsert(_ measurement: Measurement) {
        recent.removeAll { $0.id == measurement.id }
        let insertIndex = recent.firstIndex { $0.recordedAt < measurement.recordedAt } ?? recent.endIndex
        recent.insert(measurement, at: insertIndex)
    }
}
