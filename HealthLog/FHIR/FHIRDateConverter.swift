import Foundation
import ModelsR4

/// A2-L4 — non-throwing FHIR date/time construction from runtime `Date`s.
///
/// The FHIR export helpers historically used `try! DateTime(date:timeZone:)` /
/// `try! Instant(date:timeZone:)`. Those initializers throw via
/// `FHIRDate(date:)` / `FHIRTime(date:)`, so a `try!` on a value derived from
/// **runtime data** (doctor-report period, measurement timestamps) is a latent
/// crash footgun if an exotic date/timezone ever trips the FHIR validator —
/// which would crash the whole doctor-report export instead of failing one row.
///
/// This builder sidesteps the throwing path entirely by assembling the FHIR
/// primitives from `Calendar` components via the **non-throwing** memberwise
/// initializers (`FHIRDate(year:month:day:)`, `FHIRTime(hour:minute:second:)`,
/// `DateTime(date:time:timezone:)`, `InstantDate(year:month:day:)`,
/// `Instant(date:time:timezone:)`). `Calendar.dateComponents(...)` on a valid
/// Foundation `Date` always yields the needed fields, so there is no error path
/// and no `try!`.
enum FHIRDateConverter {
    static func dateTime(from date: Date, timeZone: TimeZone = .current) -> DateTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let fhirDate = FHIRDate(
            year: c.year ?? 1,
            month: UInt8(c.month ?? 1),
            day: UInt8(c.day ?? 1)
        )
        let fhirTime = FHIRTime(
            hour: UInt8(c.hour ?? 0),
            minute: UInt8(c.minute ?? 0),
            second: Decimal(c.second ?? 0)
        )
        return DateTime(date: fhirDate, time: fhirTime, timezone: timeZone)
    }

    static func instant(from date: Date, timeZone: TimeZone = .current) -> Instant {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let instantDate = InstantDate(
            year: c.year ?? 1,
            month: UInt8(c.month ?? 1),
            day: UInt8(c.day ?? 1)
        )
        let fhirTime = FHIRTime(
            hour: UInt8(c.hour ?? 0),
            minute: UInt8(c.minute ?? 0),
            second: Decimal(c.second ?? 0)
        )
        return Instant(date: instantDate, time: fhirTime, timezone: timeZone)
    }
}
