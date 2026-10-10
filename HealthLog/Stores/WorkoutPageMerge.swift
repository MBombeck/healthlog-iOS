import Foundation

/// #19 — folds one server page of `GET /api/workouts` into the rows a list
/// already holds, so a page never truncates the list and never duplicates a
/// row.
///
/// The server orders the canonical rows newest first by `startedAt` (a
/// missing start counts as the epoch), ties by `id` ascending
/// (`src/lib/workouts/list-read.ts`). A page at `offset` therefore covers a
/// contiguous window of that order: from its first row (or the very top for
/// `offset == 0`) to its last row (or the very end when the page is short).
/// Inside that window the page is the truth: held rows it no longer lists
/// were deleted, its rows replace or insert by `id`. Outside the window the
/// held rows stay as they are.
enum WorkoutPageMerge {
    static func merge(
        _ held: [WorkoutListEntryDTO],
        page: [WorkoutListEntryDTO],
        offset: Int,
        limit: Int
    ) -> [WorkoutListEntryDTO] {
        var pageIDs = Set<String>()
        let rows = page.filter { pageIDs.insert($0.id).inserted }
        guard !rows.isEmpty else { return offset == 0 ? [] : held }
        let lower = offset == 0 ? nil : rows.first
        let upper = page.count < limit ? nil : rows.last
        let kept = held.filter { row in
            !pageIDs.contains(row.id) && !isInside(row, lower: lower, upper: upper)
        }
        return (kept + rows).sorted(by: precedes)
    }

    /// Server order: newer start first, then `id` ascending.
    static func precedes(_ lhs: WorkoutListEntryDTO, _ rhs: WorkoutListEntryDTO) -> Bool {
        let left = lhs.startedAt?.timeIntervalSince1970 ?? 0
        let right = rhs.startedAt?.timeIntervalSince1970 ?? 0
        if left != right { return left > right }
        return lhs.id < rhs.id
    }

    private static func isInside(
        _ row: WorkoutListEntryDTO,
        lower: WorkoutListEntryDTO?,
        upper: WorkoutListEntryDTO?
    ) -> Bool {
        if let lower, precedes(row, lower) { return false }
        if let upper, precedes(upper, row) { return false }
        return true
    }

    /// Where paging continues after page one was merged into a longer list.
    ///
    /// - A list that was complete and now holds exactly `newTotal` rows is
    ///   complete again. A complete list that still disagrees with the total
    ///   lost or kept a row further down: the rows stay, and the next scroll
    ///   re-fetches the tail after page one.
    /// - For a partial list: when the change in the total equals the change
    ///   in held rows, every change happened inside page one and the tail
    ///   moved by that delta. Otherwise something changed further down (a
    ///   history backfill): the rows stay, the tail is re-fetched.
    static func offsetAfterFirstPage(
        heldBefore: Int,
        offsetBefore: Int,
        totalBefore: Int,
        heldAfter: Int,
        pageCount: Int,
        newTotal: Int
    ) -> Int {
        if offsetBefore >= totalBefore {
            return heldAfter == newTotal ? newTotal : pageCount
        }
        let totalDelta = newTotal - totalBefore
        if totalDelta == heldAfter - heldBefore { return max(pageCount, offsetBefore + totalDelta) }
        return pageCount
    }
}
