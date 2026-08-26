import Foundation
@testable import HealthLog
import Testing

/// Coverage for the compact past-only relative-date helper that drives
/// the Notifications channel-status line. Output rules are documented
/// on `CompactRelativeDate` itself; this suite locks the boundaries
/// (seconds → minutes → hours → days → weeks) so the surface stays
/// glanceable regardless of locale.
@Suite("CompactRelativeDate output")
struct CompactRelativeDateTests {
    /// Reference point is `now` and the helper subtracts the input from
    /// it — `relativeTo:` is the second argument so the test can pin a
    /// deterministic anchor.
    private let reference = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Sub-minute interval renders as 'jetzt' / 'now' (no unit suffix)")
    func subMinuteCollapsesToNow() {
        let past = reference.addingTimeInterval(-30)
        let result = CompactRelativeDate.string(from: past, relativeTo: reference)
        // Allow either localization — German is primary, English is
        // possible if the test host runs under EN locale.
        #expect(result == "jetzt" || result == "now")
    }

    @Test("5 minutes ago renders with compact 'min' suffix")
    func fiveMinutesAgo() {
        let past = reference.addingTimeInterval(-5 * 60)
        let result = CompactRelativeDate.string(from: past, relativeTo: reference)
        // German output is the canonical: "vor 5min". English would
        // be "5min ago". Either is acceptable depending on host locale.
        #expect(
            result == "vor 5min" || result == "5min ago",
            "unexpected formatter output: \(result)"
        )
    }

    @Test("2 hours ago renders with compact 'h' suffix")
    func twoHoursAgo() {
        let past = reference.addingTimeInterval(-2 * 60 * 60)
        let result = CompactRelativeDate.string(from: past, relativeTo: reference)
        #expect(
            result == "vor 2h" || result == "2h ago",
            "unexpected formatter output: \(result)"
        )
    }

    @Test("3 days ago renders with compact 'd' suffix")
    func threeDaysAgo() {
        let past = reference.addingTimeInterval(-3 * 24 * 60 * 60)
        let result = CompactRelativeDate.string(from: past, relativeTo: reference)
        #expect(
            result == "vor 3d" || result == "3d ago",
            "unexpected formatter output: \(result)"
        )
    }

    @Test("Future-dated input clamps to 'jetzt' (no negative numbers)")
    func futureClampsToNow() {
        // Defensive — channel-status timestamps come off the server but
        // a momentarily-skewed clock or stale cache may yield a future
        // value. The helper must never render "vor -3min".
        let future = reference.addingTimeInterval(3 * 60)
        let result = CompactRelativeDate.string(from: future, relativeTo: reference)
        #expect(result == "jetzt" || result == "now")
    }

    @Test("8 days ago renders with compact 'w' suffix")
    func oneWeekAgo() {
        let past = reference.addingTimeInterval(-8 * 24 * 60 * 60)
        let result = CompactRelativeDate.string(from: past, relativeTo: reference)
        #expect(
            result == "vor 1w" || result == "1w ago",
            "unexpected formatter output: \(result)"
        )
    }
}
