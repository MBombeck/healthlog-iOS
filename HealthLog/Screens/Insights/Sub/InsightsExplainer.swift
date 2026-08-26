import SwiftUI

/// I-0 Item 4 — the iOS twin of the web per-metric **explainer** ("Was ist X?" /
/// "Grundlage"). The web sub-page scaffold (`healthkit-metric-page.tsx`) opens a
/// static explainer from the client i18n keys `insights.subPage.explainer.<slug>`
/// `{Title,Body}` (`messages/{de,en}.json`, 45 metrics); these were ported
/// verbatim into `Localizable.xcstrings` under the SAME key scheme so the two
/// platforms stay one source of copy.
///
/// **No API.** The explainer is static editorial copy keyed by metric — there is
/// no server call. `resolve(for:)` self-suppresses (`nil`) when a metric has no
/// web explainer (`bodyFat`, `steps`, …): we never invent copy.
///
/// This is the foundation the per-metric intro (I-1) and the "Grundlage" sheet
/// card (I-2) build on — both read `InsightsExplainer.copy(slug:)`.
enum InsightsExplainer {
    /// One resolved explainer: the localized title + body for a metric.
    struct Copy: Equatable {
        let title: String
        let body: String
    }

    /// Maps a `MetricKind` onto its web explainer **slug** (the web's
    /// `explainerMetric` value — which differs from the iOS `rawValue`, e.g.
    /// `vo2Max → cardioFitness`, `timeInDaylight → daylight`,
    /// `restingHeartRate → restingHr`). Returns `nil` for kinds the web has no
    /// explainer for (`bodyFat`, `steps`) so the intro self-suppresses.
    ///
    /// A plain dictionary keeps the lookup O(1) + the contract auditable in one
    /// place (mirrors `MetricKind.availabilityKeyTable`), and dodges a 42-arm
    /// switch / the cyclomatic-complexity budget.
    static func slug(for kind: MetricKind) -> String? {
        slugTable[kind]
    }

    /// `MetricKind` → web `explainerMetric` slug. The single audit point for the
    /// kind↔explainer mapping. Kinds absent here (`bodyFat`, `steps`) have no web
    /// explainer — never invent copy.
    private static let slugTable: [MetricKind: String] = [
        .weight: "weight",
        .bloodPressure: "bloodPressure",
        .pulse: "pulse",
        .glucose: "bloodGlucose",
        .bmi: "bmi",
        .sleep: "sleep",
        .restingHeartRate: "restingHr",
        .hrv: "hrv",
        .spo2: "oxygenSaturation",
        .vo2Max: "cardioFitness",
        .respiratoryRate: "respiratoryRate",
        .bodyTemperature: "bodyTemperature",
        .skinTemperature: "skinTemperature",
        .wristTemperature: "wristTemperature",
        .bodyWater: "bodyWater",
        .boneMass: "boneMass",
        .activeEnergy: "activeEnergy",
        .flightsClimbed: "flightsClimbed",
        .timeInDaylight: "daylight",
        .fatFreeMass: "fatFreeMass",
        .fatMass: "fatMass",
        .leanBodyMass: "leanBodyMass",
        .muscleMass: "muscleMass",
        .visceralFat: "visceralFat",
        .pulseWaveVelocity: "pulseWaveVelocity",
        .vascularAge: "vascularAge",
        .walkingHeartRate: "walkingHeartRate",
        .walkingSpeed: "walkingSpeed",
        .walkingAsymmetry: "walkingAsymmetry",
        .walkingSteadiness: "walkingSteadiness",
        .walkingStepLength: "stepLength",
        .walkingDoubleSupport: "doubleSupportTime",
        .distanceWalkingRunning: "walkingDistance",
        .stairAscentSpeed: "stairAscentSpeed",
        .stairDescentSpeed: "stairDescentSpeed",
        .sixMinuteWalk: "sixMinuteWalk",
        .falls: "falls",
        .breathingDisturbances: "breathingDisturbances",
        .cardioRecovery: "cardioRecovery",
        .audioExposureHeadphone: "headphoneAudio",
        .audioExposureEnvironment: "environmentalAudio"
    ]

    /// Resolves the explainer copy for a metric kind, or `nil` when none exists.
    static func resolve(for kind: MetricKind) -> Copy? {
        guard let slug = slug(for: kind) else { return nil }
        return copy(slug: slug)
    }

    /// Resolves the explainer copy for a raw web slug (used by the special pages
    /// `mood` / `medications` that have no `MetricKind`). `nil` when absent.
    static func copy(slug: String) -> Copy? {
        guard let title = resolved("insights.subPage.explainer.\(slug)Title"),
              let body = resolved("insights.subPage.explainer.\(slug)Body") else { return nil }
        return Copy(title: title, body: body)
    }

    /// The "Was ist X?" trigger label, with the title interpolated.
    static func triggerLabel(title: String) -> String {
        String(format: String(localized: "insights.subPage.explainer.trigger"), title)
    }

    /// Resolves a catalog key, treating an absent entry (the key echoes back) or
    /// an empty value as "no copy" → `nil`. Mirrors the `descriptionSlot`
    /// echo-test in `InsightsMetricScreen`.
    private static func resolved(_ key: String) -> String? {
        let value = String(localized: String.LocalizationValue(key))
        guard value != key, !value.isEmpty else { return nil }
        return value
    }
}

/// I-0 Item 3/4 — the per-page **intro** paragraph, rendered identically to the
/// canonical `InsightsMetricScreen.descriptionSlot`: the explainer body as calm
/// secondary body prose, self-suppressing when absent. Used by the mood +
/// medications special pages (which previously showed only the page subtitle and
/// looked broken next to the metric pages that carry a server intro).
struct InsightsExplainerIntro: View {
    let slug: String

    var body: some View {
        if let copy = InsightsExplainer.copy(slug: slug) {
            Text(copy.body)
                .font(.hlBody)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("insights.explainer.intro.\(slug)")
        }
    }
}
