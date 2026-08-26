import SwiftUI

/// Says out loud that two sources disagreed about one night (parity Build 4 ·
/// item 4.7; audit `09-…md:136` — iOS previously dropped the field entirely at
/// the `CodingKeys` level).
///
/// The server dedups a multi-source night by picking ONE canonical writer off
/// the user's source ladder and serving its totals. That is the right call for
/// producing a single number, but it leaves a night where the phone said 6 h
/// and the strap said 7 h 20 m looking exactly like a night where every source
/// agreed. When two sources disagree about the same night, saying so is better
/// than silently presenting the winner as settled fact — so this note names
/// every bucket and its own claim, and the headline totals above read as "the
/// one we chose" rather than "the only one there was".
///
/// Self-suppresses on the ordinary single-source night: no layout shift, and
/// no alarm where there is nothing to be alarmed about.
struct SleepSourceDiscrepancyNote: View {
    let session: SleepSession

    var body: some View {
        if let discrepancy = session.sourceDiscrepancy, !discrepancy.sources.isEmpty {
            VStack(alignment: .leading, spacing: HLSpace.xxs) {
                Label {
                    Text("sleep.sourceDiscrepancy.title")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .labelStyle(.titleAndIcon)
                Text(Self.detail(discrepancy))
                    .font(.hlCaption2)
                    .foregroundStyle(HLText.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// `"Apple Health 7 h 12 min · WHOOP 6 h 30 min — 42 min apart"`.
    ///
    /// Bucket order is the SERVER's (most asleep minutes first) and is left
    /// untouched: any re-ranking on the client would be an opinion about which
    /// source is more credible, which is exactly the judgement this note
    /// declines to make. A device type, when the server split the bucket on
    /// one, names the writer more precisely than the source enum does.
    nonisolated static func detail(_ discrepancy: SleepSourceDiscrepancy) -> String {
        let claims = discrepancy.sources.map { bucket in
            let name = if let deviceType = bucket.deviceType, !deviceType.isEmpty {
                deviceType
            } else {
                SourcePriorityRow.displayLabel(forSource: bucket.source)
            }
            return "\(name) \(SleepDurationFormat.hoursMinutes(bucket.asleepMinutes))"
        }.joined(separator: " · ")
        guard discrepancy.deltaMinutes > 0 else { return claims }
        let delta = SleepDurationFormat.hoursMinutes(discrepancy.deltaMinutes)
        return String(localized: "sleep.sourceDiscrepancy.detail \(claims) \(delta)")
    }
}
