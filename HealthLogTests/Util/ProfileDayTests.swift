import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **#115 1.5 — the profile-zone day calendar and its sites.**
///
/// Every test pins the zone and the instant. The instant used throughout,
/// 2026-06-19T03:00Z, is 2026-06-18 20:00 in Los Angeles, 2026-06-19 05:00 in
/// Berlin (this machine) and 2026-06-19 12:00 in Tokyo, so a result that
/// silently falls back to the device zone answers the wrong day for at least
/// one of the profile zones below.
@MainActor
@Suite("ProfileDay — server day keys in the account zone (#115 1.5)")
struct ProfileDayTests {
    private static let instantText = "2026-06-19T03:00:00Z"

    private func instant() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: Self.instantText))
    }

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    @Test("An instant's key is its day in the given zone")
    func keyForInstant() throws {
        let now = try instant()
        #expect(try ProfileDay.key(for: now, timeZone: zone("America/Los_Angeles")) == "2026-06-18")
        #expect(try ProfileDay.key(for: now, timeZone: zone("Asia/Tokyo")) == "2026-06-19")
    }

    @Test("A day anchor round-trips through its key in every zone")
    func anchorRoundTrip() throws {
        let anchor = try #require(ProfileDay.anchor(forKey: "2026-03-29"))
        // The same instant `JSONDecoder.hlDefault` produces for "2026-03-29".
        struct Box: Decodable { let date: Date }
        let decoded = try JSONDecoder.hlDefault.decode(Box.self, from: Data(#"{"date":"2026-03-29"}"#.utf8))
        #expect(decoded.date == anchor)
        #expect(ProfileDay.key(ofAnchor: anchor) == "2026-03-29")
        #expect(ProfileDay.anchor(forKey: "2026-02-30") == nil)
        #expect(ProfileDay.anchor(forKey: "not-a-day") == nil)
    }

    @Test("Adding days is calendar arithmetic, safe across a DST switch")
    func addingDays() {
        #expect(ProfileDay.key("2026-03-28", addingDays: 1) == "2026-03-29")
        #expect(ProfileDay.key("2026-03-29", addingDays: 1) == "2026-03-30")
        #expect(ProfileDay.key("2026-01-01", addingDays: -1) == "2025-12-31")
        #expect(ProfileDay.key("2026-06-18", addingDays: -365) == "2025-06-18")
    }

    @Test("startOfDay(forKey:) is the zone's midnight of that day")
    func startOfDayForKey() throws {
        let losAngeles = try zone("America/Los_Angeles")
        let start = try #require(ProfileDay.startOfDay(forKey: "2026-06-18", timeZone: losAngeles))
        #expect(ProfileDay.key(for: start, timeZone: losAngeles) == "2026-06-18")
        #expect(try start == #require(ISO8601DateFormatter().date(from: "2026-06-18T07:00:00Z")))
    }

    @Test("anchor(for:) is the account's today in the date-only representation")
    func anchorForInstant() throws {
        let now = try instant()
        let anchor = try ProfileDay.anchor(for: now, timeZone: zone("America/Los_Angeles"))
        #expect(ProfileDay.key(ofAnchor: anchor) == "2026-06-18")
    }

    // MARK: - Sites

    @Test("Mood from/to are the account's last N days")
    func moodWindow() throws {
        let now = try instant()
        let la = try MoodRepository.dayWindow(days: 30, now: now, timeZone: zone("America/Los_Angeles"))
        #expect(la.from == "2026-05-19")
        #expect(la.to == "2026-06-18")
        let tokyo = try MoodRepository.dayWindow(days: 30, now: now, timeZone: zone("Asia/Tokyo"))
        #expect(tokyo.to == "2026-06-19")
    }

    @Test("Mood history presets are cut in the profile calendar")
    func moodHistoryPreset() throws {
        let now = try instant()
        let filter = MoodHistoryFilter(period: .last7Days)
        let query = try filter.query(limit: 25, offset: 0, now: now, calendar: ProfileDay.calendar(in: zone("America/Los_Angeles")))
        #expect(query.from == "2026-06-12")
        #expect(query.to == "2026-06-18")
    }

    @Test("Sleep's today, the cycle window's today and an illness day follow the account")
    func todayKeys() throws {
        let now = try instant()
        let losAngeles = try zone("America/Los_Angeles")
        #expect(SleepNightRepository.dayKey(for: now, timeZone: losAngeles) == "2026-06-18")
        #expect(CycleCalendarWindow.todayKey(date: now, timeZone: losAngeles) == "2026-06-18")
        #expect(LogDaySheet.dayKey(for: now, timeZone: losAngeles) == "2026-06-18")
        #expect(CycleCaptureSheet.dayKey(now, timeZone: losAngeles) == "2026-06-18")
        let tokyo = try zone("Asia/Tokyo")
        #expect(SleepNightRepository.dayKey(for: now, timeZone: tokyo) == "2026-06-19")
        #expect(CycleCalendarWindow.todayKey(date: now, timeZone: tokyo) == "2026-06-19")
    }

    @Test("A course day survives the editor's round trip on every device zone")
    func courseDayRoundTrip() throws {
        // A stored `startsOn: "2026-07-10"` decodes to UTC midnight. The row's
        // picker hands back an instant inside the chosen UTC day; the save path
        // must re-send exactly "2026-07-10". The old row normalised with the
        // device calendar: in Berlin that is 2026-07-09 22:00Z, which reads back
        // as the ninth; west of UTC the stored day already SHOWED as the ninth.
        let stored = try #require(ProfileDay.anchor(forKey: "2026-07-10"))
        let picked = stored.addingTimeInterval(9 * 3600)
        #expect(MedicationCadenceLogic.courseDay(CourseWindowRow.normalized(picked)) == "2026-07-10")
        #expect(MedicationCadenceLogic.courseDay(CourseWindowRow.normalized(stored)) == "2026-07-10")
        // A new course starts on the account's today.
        let today = try CourseWindowRow.today(now: instant(), timeZone: zone("America/Los_Angeles"))
        #expect(MedicationCadenceLogic.courseDay(today) == "2026-06-18")
    }
}

/// **#115 1.5 — the mood list request carries the account's days.** Drives the
/// real `MoodRepository` over the real `APIClient`; the zone is injected, the
/// clock is live, so the two zones (25 h apart) cannot both match any single
/// device zone — a device-zone `from`/`to` fails at least one of them.
@Suite("MoodRepository — from/to in the profile zone (#115 1.5)", .serialized)
struct MoodRepositoryProfileWindowTests {
    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URLQueryItem] = []
        func set(_ value: [URLQueryItem]) {
            lock.lock()
            items = value
            lock.unlock()
        }

        func value(_ name: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return items.first { $0.name == name }?.value
        }
    }

    @Test("to is today in the profile zone, from is N days before it")
    func windowFollowsProfile() async throws {
        for identifier in ["Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let zone = try #require(TimeZone(identifier: identifier))
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let captured = Captured()
            session.install { req in
                if req.url?.path == "/api/mood-entries" {
                    captured.set(URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                }
                let body = #"{"data":{"entries":[],"meta":{"total":0}},"error":null}"#
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            let env = AppEnvironment(baseURL: session.baseURL, bundleID: "dev.healthlog.app", appVersion: "0.1.0", buildNumber: "1")
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: session.configuration)
            let repo = try MoodRepository(api: api, outbox: OutboxQueue(inMemory: true), profileTimeZone: { zone })

            _ = try await repo.recent(days: 30)

            let today = ProfileDay.key(for: .now, timeZone: zone)
            #expect(captured.value("to") == today, "\(identifier)")
            #expect(captured.value("from") == ProfileDay.key(today, addingDays: -30), "\(identifier)")
        }
    }
}

// swiftlint:enable force_unwrapping
