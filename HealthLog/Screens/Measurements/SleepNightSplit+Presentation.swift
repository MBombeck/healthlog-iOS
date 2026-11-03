import SwiftUI

// #146 (server v1.43.7) — where the app says "night" it shows the night.
//
// A sleep row's headline stays the server's `value`: the day's whole sleep,
// the same number the chart, the sleep score and the Today tile show. On a day
// with naps the row (and the metric page's "Last measurement") adds one caption
// that names the parts as the server sent them. A day without naps gets no
// caption at all: its total already is its night.

extension SleepNightSplit {
    /// "Night 7 h 10 min, naps 40 min", "Naps only", or `nil` when the day had
    /// no naps (or the server sent nothing to split).
    var breakdownLine: String? {
        let napMinutes = Int(napAsleepMinutes.rounded())
        guard hasNaps, napMinutes > 0 else { return nil }
        let naps = SleepDurationFormat.hoursMinutes(napMinutes)
        guard let main = mainAsleepMinutes.map({ Int($0.rounded()) }), main > 0 else {
            return String(localized: "sleep.split.napsOnly")
        }
        let night = SleepDurationFormat.hoursMinutes(main)
        return String(localized: "sleep.split.nightAndNaps \(night) \(naps)")
    }
}

/// The one caption line the measurement list row and the metric page's "Last
/// measurement" show under a sleep day; nothing at all on a day without naps.
struct SleepSplitCaption: View {
    let split: SleepNightSplit?

    var body: some View {
        if let line = split?.breakdownLine {
            Text(line)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
        }
    }
}
