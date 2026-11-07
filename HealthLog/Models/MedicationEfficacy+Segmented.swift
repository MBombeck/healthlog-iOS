import Foundation

/// **MED (#149) — the carry-over caveat of the segmented fit.**
///
/// Server v1.46 adds `targets[].segmented` to `GET /api/medications/{id}/efficacy`:
/// a segmented regression around the start with a `fit` block. When the lag-1
/// residual autocorrelation exceeds 0.5 the server sets
/// `fit.autocorrelationCaveat: true`: the day-to-day carry-over is strong
/// enough that the comparison is less certain than it looks, and the read-out
/// says so. The app reads only that flag and renders one foot line; it
/// never recomputes anything from the fit.
///
/// Decoding is tolerant on purpose: an unexpected `segmented` shape costs the
/// caveat, never the efficacy card.
public extension MedicationEfficacyDTO.Target {
    struct Segmented: Decodable, Sendable {
        public let fit: Fit?

        public struct Fit: Decodable, Sendable {
            public let autocorrelationCaveat: Bool?
        }

        public init(fit: Fit?) {
            self.fit = fit
        }

        public init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            fit = try? container?.decodeIfPresent(Fit.self, forKey: .fit)
        }

        private enum CodingKeys: String, CodingKey {
            case fit
        }
    }

    /// `true` only when the server sent `fit.autocorrelationCaveat: true`.
    var showsAutocorrelationCaveat: Bool {
        segmented?.fit?.autocorrelationCaveat == true
    }

    /// The card's foot line for the caveat, or `nil`.
    var autocorrelationCaveatText: String? {
        showsAutocorrelationCaveat ? String(localized: "med.wirkung.autocorrelationCaveat") : nil
    }
}
