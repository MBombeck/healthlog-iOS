import Foundation

/// The macro day totals this device posted with an amount, per account.
///
/// The nutrient read skips days without samples, so a day whose last protein
/// sample was deleted in Apple Health would keep its old total on the server.
/// The contract's correction is a re-post of `0` (last writer wins per day,
/// nutrient and source): a day this ledger remembers with an amount, read
/// again inside the window and now without any, goes out as `0`.
struct NutrientMacroDayLedger {
    /// Days older than this fall out of the ledger; no sweep reads that far.
    static let keepDays = 45

    let defaults: UserDefaults
    let partition: String

    private var key: String {
        "hl.nutrients.macroDays." + partition
    }

    /// `code|yyyy-MM-dd` of every macro day posted with an amount.
    var postedDays: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    /// `entries` plus a `0` for every remembered macro day in
    /// `[fromDay, toDay]` the read no longer returned.
    ///
    /// A `0` goes out only for a code that still has samples on another day
    /// of the same window. A code whose whole window reads empty although it
    /// had totals looks exactly like revoked read access: nothing is sent,
    /// and ``unreadableKey`` tells Sync Diagnostics to suggest checking the
    /// permissions.
    func withZeroCorrections(_ entries: [NutrientIntakeEntryDTO], fromDay: String, toDay: String) -> [NutrientIntakeEntryDTO] {
        let present = Set(entries.map { $0.nutrient.rawValue + "|" + $0.day })
        let readCodes = Set(entries.map(\.nutrient.rawValue))
        var unreadable = false
        let units = Dictionary(uniqueKeysWithValues: NutrientCatalog.macros.map { ($0.code.rawValue, ($0.code, $0.unit)) })
        var corrected = entries
        for posted in postedDays.sorted() where !present.contains(posted) {
            let parts = posted.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] >= fromDay, parts[1] <= toDay, let item = units[parts[0]] else { continue }
            guard readCodes.contains(parts[0]) else {
                unreadable = true
                continue
            }
            corrected.append(NutrientIntakeEntryDTO(day: parts[1], nutrient: item.0, unit: item.1, amount: 0))
        }
        defaults.set(unreadable, forKey: Self.unreadableKey)
        return corrected
    }

    /// Set when the last sweep found macro totals it could no longer read.
    static let unreadableKey = "hl.nutrients.macroUnreadable"

    static func isUnreadable(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: unreadableKey)
    }

    /// After a sweep that landed: remember the macro days posted with an
    /// amount, forget those posted as `0` and those older than ``keepDays``.
    func remember(_ posted: [NutrientIntakeEntryDTO], oldestDay: String) {
        let macroCodes = Set(NutrientCatalog.macros.map(\.code))
        var days = postedDays
        for entry in posted where macroCodes.contains(entry.nutrient) {
            let id = entry.nutrient.rawValue + "|" + entry.day
            if entry.amount > 0 { days.insert(id) } else { days.remove(id) }
        }
        days = days.filter { ($0.split(separator: "|").last.map(String.init) ?? "") >= oldestDay }
        defaults.set(days.sorted(), forKey: key)
    }

    /// ``withZeroCorrections(_:fromDay:toDay:)`` over a sweep window, while
    /// the server takes macros (contract §5).
    func correcting(_ entries: [NutrientIntakeEntryDTO], from: Date, to now: Date, calendar: Calendar) -> [NutrientIntakeEntryDTO] {
        guard AppleHealthIngestCapability.isAvailable(.nutrientMacros, defaults: defaults) else { return entries }
        return withZeroCorrections(entries, fromDay: Self.dayKey(from, calendar: calendar), toDay: Self.dayKey(now, calendar: calendar))
    }

    func remember(_ posted: [NutrientIntakeEntryDTO], now: Date, calendar: Calendar) {
        let oldest = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) ?? now
        remember(posted, oldestDay: Self.dayKey(oldest, calendar: calendar))
    }

    /// `yyyy-MM-dd` in `calendar`, the day key the nutrient reads use.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
