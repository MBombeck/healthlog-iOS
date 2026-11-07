import Foundation

/// **MED (#126, server v1.42.2) — a dose the server recorded by itself.**
///
/// With `autoMarkTaken` on, the server records each scheduled dose as taken
/// shortly after its time (`autoRecorded: true`, `takenAt` = the slot time).
/// It counts as taken everywhere; the history row only says "Recorded
/// automatically" in its existing caption. A take or skip the person records
/// clears the flag on the server, and a skipped row never carries the caption.
public extension MedicationDoseHistoryRow.Intake {
    var isAutoRecordedTake: Bool {
        autoRecorded == true && !skipped && takenAt != nil
    }
}

public extension PaginatedIntakeEvent {
    var isAutoRecordedTake: Bool {
        autoRecorded == true && !skipped && takenAt != nil
    }
}
