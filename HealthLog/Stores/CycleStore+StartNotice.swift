import Foundation

/// #137 (server v1.43) — merged and restored cycle starts, said once.
///
/// The calendar is still reloaded after every boundary write (#115 1.6); the
/// server's new fields only add the sentence. The writes in `CycleStore` set
/// ``CycleStore/startNotice`` from a start's `absorbed`; this extension covers
/// the edit path (a cleared flow on a start day can give a start back) and the
/// dismissal.
extension CycleStore {
    /// ``CycleRepository/updateDayLogReportingStarts(id:patch:)`` that keeps the server's
    /// `restored` list as the calendar's notice.
    func updateDayLogNotingStarts(id: String, patch: CycleDayLogPatch) async throws -> CycleDayLogDTO {
        let result = try await repository.updateDayLogReportingStarts(id: id, patch: patch)
        if let notice = CycleStartNotice.restored(result.restored) { startNotice = notice }
        return result.dayLog
    }

    /// The person closed the notice (or the calendar moved on).
    public func dismissStartNotice() {
        startNotice = nil
    }
}
