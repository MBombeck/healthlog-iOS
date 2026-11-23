import Foundation

/// #191 (server 1.49.0, key `day.dose-offset`) — where a symptom sits
/// against the day's doses: `doseOffset` on each occurrence of
/// `GET /api/symptoms/events`, the same object as on day events. The server
/// cuts the day in the profile zone (`load-day.ts`), so the app never keys a
/// symptom's day itself.
///
/// The anchor is the nearest dose taken at or before the symptom, else the
/// nearest one after it (then `minutes` is negative). A distance in time and
/// nothing more, never a cause; the app words it and never recomputes it
/// (`src/lib/day/dose-offsets.ts`).
public struct DayDoseOffset: Codable, Sendable, Equatable, Hashable {
    /// The anchoring intake event's id.
    public let intakeId: String
    /// The medication's name.
    public let title: String
    /// Minutes from the dose to the symptom: positive after it, negative before.
    public let minutes: Int

    public init(intakeId: String, title: String, minutes: Int) {
        self.intakeId = intakeId
        self.title = title
        self.minutes = minutes
    }
}
