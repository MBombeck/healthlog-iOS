import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

/// Basal body temperature from Apple Health, sent as `basalBodyTempC` on the
/// cycle day-log (#181; the server has taken the field since the cycle
/// routes shipped).
///
/// It rides the cycle import: read only while cycle tracking runs, keyed on
/// the same `cycle-hk:<day>` id as the other reproductive samples, so the
/// server folds it into that day's row. It is a read type only; HealthLog never
/// writes it back.
///
/// **Asking.** Not part of the reproductive sheet, which the cycle store asks
/// for on every launch: a returning person would get a system sheet out of
/// nowhere. It is one of the announced late-read types instead and is asked
/// on the "new data types" card or the Apple Health settings page, and only
/// while cycle tracking runs on this device.
///
/// **History.** A first read walks the samples oldest first, one bounded page
/// per sweep, so an installation that has years of temperatures sends them a
/// page at a time instead of all at once.
enum CycleBasalTemperature {
    static let identifier = "HKQuantityTypeIdentifierBasalBodyTemperature"

    /// One anchored page per sweep, at the bulk route's bound.
    static let pageLimit = 500

    /// The device-level fact "the cycle import runs here", written by the
    /// importer's start and stop. Read by the late-read card and Sync
    /// Diagnostics, which have no cycle gate of their own.
    static let importActiveKey = "hl.cycle.hk.importActive"

    static func isCycleImportActive(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: importActiveKey)
    }

    static func recordCycleImport(active: Bool, defaults: UserDefaults = .standard) {
        if active {
            defaults.set(true, forKey: importActiveKey)
        } else {
            defaults.removeObject(forKey: importActiveKey)
        }
    }

    /// A plausible basal temperature in °C: the day-log refuses values far
    /// outside the human range, and a slipped Fahrenheit value would land
    /// there.
    static func plausibleCelsius(_ value: Double) -> Double? {
        (30.0 ... 45.0).contains(value) ? (value * 100).rounded() / 100 : nil
    }

    #if canImport(HealthKit)
        static var sampleType: HKQuantityType? {
            HKObjectType.quantityType(forIdentifier: .basalBodyTemperature)
        }

        /// The day-log fields of one foreign temperature sample, or `nil` for
        /// this app's own write and an implausible value.
        static func celsius(of sample: HKQuantitySample) -> Double? {
            guard !HealthKitSampleOwnership.isOwnEcho(sample),
                  sample.quantity.is(compatibleWith: .degreeCelsius()) else { return nil }
            return plausibleCelsius(sample.quantity.doubleValue(for: .degreeCelsius()))
        }
    #endif
}
