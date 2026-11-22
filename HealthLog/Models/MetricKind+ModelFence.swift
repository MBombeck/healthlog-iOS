import Foundation

// The kinds no language model is handed.
//
// The server keeps mindful minutes, the State of Mind valence and AFib burden
// off every AI-facing surface (`signals/registry.ts` v1.44, and
// `MODEL_FENCED_CHANNELS` in `correlation-discovery.ts`): mental-health
// self-reports and an AFib awareness signal are shared only where the person
// asks. The app's own coach digest follows the same line.

extension MetricKind {
    /// `true` for a kind that never goes into a model prompt.
    var isModelFenced: Bool {
        switch self {
        case .mindfulMinutes, .stateOfMindValence, .afibBurden: true
        // Off the coach snapshot on the server as well (`coachSnapshot: false`).
        case .bloodKetones, .basalEnergy, .indoorCO2, .indoorTemperature, .indoorHumidity: true
        default: false
        }
    }

    /// ``selectableCases`` without the fenced kinds: what a coach digest may
    /// enumerate.
    static var coachCases: [MetricKind] {
        selectableCases.filter { !$0.isModelFenced }
    }

    /// The EN prompt word of the server-v1.44 kinds (`MiniCoachDataBinder`).
    /// The fenced three never reach a prompt; they are named for completeness.
    var server144PromptName: String {
        switch self {
        case .exerciseMinutes: "exercise minutes"
        case .standMinutes: "stand minutes"
        case .standHours: "stand hours"
        case .mindfulMinutes: "mindful minutes"
        case .stateOfMindValence: "state of mind (valence)"
        case .afibBurden: "AFib burden"
        case .bloodKetones: "blood ketones"
        case .basalEnergy: "resting energy"
        case .indoorCO2: "indoor CO2"
        case .indoorTemperature: "indoor temperature"
        case .indoorHumidity: "indoor humidity"
        default: rawValue
        }
    }
}
