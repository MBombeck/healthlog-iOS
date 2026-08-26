import Foundation
import Observation

/// v0.5.3-F3 — `@Observable` wrapper über `SourcePriorityRepository`.
///
/// Treibt die Read-Only-Anzeige der per-User-Source-Priority-Leiter unter
/// `SettingsSourcesScreen` **plus** den vollen Editor unter
/// `SourcePriorityEditorScreen` (v0.5.4-SP4).
///
/// **Cache-Verhalten:** Repo-seitig 5min TTL, nach `update(_:)` wird der
/// Server-Echo zurückgespielt. Für die Read-Only-Variante reicht `load()`.
///
/// **Write-Pfad (v0.5.4-SP4):**
///   - `updateLadder(forMetric:to:)` mutiert die nested `metricPriority`-Map
///     plus den flachen W5e-Alias optimistisch, schiebt den PUT raus, rollt
///     bei Server-Fehler auf den vorigen Snapshot zurück.
///   - `resetToDefaults()` legt die kanonische Default-Leiter (siehe
///     `defaultLadder(forMetric:)`) für jede Metric an und PUTet komplett.
///   - Beide Pfade nutzen `repo.update(_:idempotencyKey:)`, generieren also
///     deterministisch einen Replay-fähigen Key.
@MainActor
@Observable
public final class SourcePriorityStore {
    public private(set) var ladder: SourcePriorityDTO?
    public private(set) var isLoading: Bool = false
    public private(set) var isSaving: Bool = false
    public private(set) var error: HLError?

    private let repo: SourcePriorityRepository

    public init(repo: SourcePriorityRepository) {
        self.repo = repo
    }

    public func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            ladder = try await repo.fetch()
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func refresh() async {
        await load()
    }

    public func clearOnLogout() {
        ladder = nil
        error = nil
        isSaving = false
    }

    // MARK: - Editor write path (v0.5.4-SP4)

    /// Optimistisch eine einzelne Metric-Ladder ersetzen. Rollback bei
    /// Server-Fehler. Returns `true` bei Erfolg — Caller kann das nutzen,
    /// um Haptik / Visual-Confirmation zu triggern.
    @discardableResult
    public func updateLadder(forMetric key: String, to sources: [String]) async -> Bool {
        let previous = ladder
        let next = mutating(previous ?? SourcePriorityDTO(), settingLadder: sources, forMetric: key)
        ladder = next
        return await persist(next, rollbackTo: previous)
    }

    /// Setzt **alle** Leitern auf den kanonischen Default (`APPLE_HEALTH`,
    /// `WITHINGS`, `MANUAL` für die meisten Metriken — siehe
    /// `defaultLadder(forMetric:)`). Optimistisch, Rollback bei Fehler.
    @discardableResult
    public func resetToDefaults() async -> Bool {
        let previous = ladder
        var next = SourcePriorityDTO()
        for key in SourcePriorityStore.canonicalMetricKeys {
            next = mutating(next, settingLadder: SourcePriorityStore.defaultLadder(forMetric: key), forMetric: key)
        }
        ladder = next
        return await persist(next, rollbackTo: previous)
    }

    private func persist(_ payload: SourcePriorityDTO, rollbackTo previous: SourcePriorityDTO?) async -> Bool {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let echoed = try await repo.update(payload, idempotencyKey: IdempotencyKey())
            ladder = echoed
            return true
        } catch let err as HLError {
            ladder = previous
            error = err
            return false
        } catch {
            ladder = previous
            self.error = .unknown(String(describing: error))
            return false
        }
    }

    /// Pure helper — produces a new DTO mit der eingestellten Source-Liste
    /// für eine Metric. Hält **beide** Shapes konsistent (nested
    /// `metricPriority` + flacher Top-Level-Alias) damit Server-Snapshots
    /// nicht versehentlich auseinanderlaufen.
    ///
    /// Routes both shape-writes through `SourcePriorityDTO.replacingLadder
    /// (forMetric:to:)` — the DTO owns the key→property mapping so this
    /// method stays a thin, low-complexity orchestrator.
    func mutating(
        _ source: SourcePriorityDTO,
        settingLadder sources: [String],
        forMetric key: String
    ) -> SourcePriorityDTO {
        source.replacingLadder(forMetric: key, to: sources)
    }

    /// Surface-friendly derivation: a fixed, ordered list of (metricKey,
    /// localized label, source list) for the iOS UI. The set + order is
    /// locked here so a SnapshotTest can pin the matrix.
    public var metricEntries: [SourcePriorityRow] {
        guard let ladder else { return [] }
        return SourcePriorityStore.canonicalMetricKeys.compactMap { key in
            guard let sources = ladder.ladder(forMetric: key) else { return nil }
            return SourcePriorityRow(
                metricKey: key,
                label: SourcePriorityStore.label(forMetricKey: key),
                sources: sources
            )
        }
    }

    /// Ordered set of metric keys we surface in the iOS read-only view.
    /// Matches the order the web's `sources-section.tsx` editor uses.
    public static let canonicalMetricKeys: [String] = [
        "steps",
        "activeEnergy",
        "walkingRunningDistance",
        "flightsClimbed",
        "sleep",
        "weight",
        "bloodPressure",
        "pulse",
        "bodyFat",
        "bodyTemperature",
        "spo2",
        "hrv",
        "restingHeartRate",
        "respiratoryRate",
        "skinTemperature",
        "vo2Max",
        "recovery",
        // Build 2 / 2.6 — the last two web keys iOS never picked up (web had
        // 19, iOS 17). `stress` landed server-side in v1.18.10 (I-5),
        // `sleepDebt` in v1.25.0; both are native-vs-computed ladders.
        "stress",
        "sleepDebt"
    ]

    /// Maps a wire metric-key (`steps`, `weight`, …) to the user-facing
    /// German label. Single source of truth for the read-only view +
    /// snapshot tests. Dictionary-driven so SwiftLint's cyclomatic-
    /// complexity ceiling stays out of the picture as the list grows.
    public static func label(forMetricKey key: String) -> String {
        SourcePriorityStore.labels[key] ?? key.capitalized
    }

    private static let labels: [String: String] = [
        "steps": "Steps",
        "activeEnergy": "Aktive Energie",
        "walkingRunningDistance": "Distanz (Gehen / Laufen)",
        "flightsClimbed": "Stockwerke",
        "sleep": "Sleep",
        "weight": "Weight",
        "bloodPressure": "Blood pressure",
        "pulse": "Pulse",
        "bodyFat": "Body fat",
        "bodyTemperature": "Körpertemperatur",
        "spo2": "Oxygen saturation",
        "hrv": "Herzfrequenzvariabilität",
        "restingHeartRate": "Resting heart rate",
        "respiratoryRate": "Respiratory rate",
        "skinTemperature": "Skin temperature",
        "vo2Max": "VO₂ max",
        "recovery": "Recovery",
        "stress": "Stress",
        "sleepDebt": "Schlafdefizit"
    ]

    /// Kanonische Default-Reihenfolge pro Metrik. Mirrors server-side
    /// `DEFAULT_SOURCE_PRIORITY` (`src/lib/validations/source-priority.ts`,
    /// confirmed verbatim in coord note
    /// `v1.12.0-server-to-ios-source-ladder-and-meds-ack.md`) so "Auf Standard
    /// zurücksetzen" auf iOS dasselbe Ergebnis liefert wie der Web-Reset.
    ///
    /// **Server map (verbatim):**
    ///   - cumulative activity → `APPLE_HEALTH > WITHINGS > FITBIT > MANUAL`
    ///   - recovery inputs (sleep/hrv/restingHeartRate/respiratoryRate) →
    ///     `WHOOP > FITBIT > APPLE_HEALTH > WITHINGS`
    ///   - weight → `WITHINGS > APPLE_HEALTH > MANUAL > WHOOP > FITBIT`
    ///   - pulse/bodyFat/bodyTemperature → `WITHINGS > APPLE_HEALTH > MANUAL > FITBIT`
    ///   - spo2 → `WITHINGS > WHOOP > FITBIT > APPLE_HEALTH > MANUAL`
    ///   - skinTemperature → `WITHINGS > WHOOP > FITBIT > APPLE_HEALTH`
    ///   - vo2Max → `WITHINGS > APPLE_HEALTH > FITBIT > MANUAL`
    ///   - recovery → `WHOOP > COMPUTED`
    ///   - bloodPressure → `WITHINGS > APPLE_HEALTH > MANUAL` (no WHOOP/FITBIT —
    ///     neither device reports BP)
    ///
    /// `IMPORT` is intentionally **not** part of any default ladder — the token
    /// only appears once the user ran a bulk-CSV import.
    public static func defaultLadder(forMetric key: String) -> [String] {
        switch key {
        case "steps", "activeEnergy", "walkingRunningDistance", "flightsClimbed":
            ["APPLE_HEALTH", "WITHINGS", "FITBIT", "MANUAL"]
        case "sleep", "hrv", "restingHeartRate", "respiratoryRate":
            ["WHOOP", "FITBIT", "APPLE_HEALTH", "WITHINGS"]
        case "weight":
            ["WITHINGS", "APPLE_HEALTH", "MANUAL", "WHOOP", "FITBIT"]
        case "pulse", "bodyFat", "bodyTemperature":
            ["WITHINGS", "APPLE_HEALTH", "MANUAL", "FITBIT"]
        case "spo2":
            ["WITHINGS", "WHOOP", "FITBIT", "APPLE_HEALTH", "MANUAL"]
        case "skinTemperature":
            ["WITHINGS", "WHOOP", "FITBIT", "APPLE_HEALTH"]
        case "vo2Max":
            ["WITHINGS", "APPLE_HEALTH", "FITBIT", "MANUAL"]
        case "recovery":
            ["WHOOP", "COMPUTED"]
        // Verbatim from the server's `DEFAULT_SOURCE_PRIORITY`
        // (`src/lib/validations/source-priority.ts:392,397`) so the iOS reset
        // yields exactly the web reset.
        case "stress":
            ["OURA", "COMPUTED"]
        case "sleepDebt":
            ["WHOOP", "OURA", "POLAR", "COMPUTED"]
        case "bloodPressure":
            ["WITHINGS", "APPLE_HEALTH", "MANUAL"]
        default:
            ["APPLE_HEALTH", "WITHINGS", "MANUAL"]
        }
    }

    /// Kanonische Source-Token, die der Editor anbieten darf — auch für
    /// Metriken, deren Server-Snapshot weniger Quellen kennt. Sorgt dafür,
    /// dass der Operator selbst dann die volle Auswahl sieht, wenn ein
    /// Datentyp z.B. heute nur `APPLE_HEALTH`-Werte hat, morgen aber ein
    /// `WITHINGS`-Sensor synced.
    public static let canonicalSourceTokens: [String] = [
        "APPLE_HEALTH",
        "WITHINGS",
        "WHOOP",
        "FITBIT",
        "OURA",
        "POLAR",
        "NIGHTSCOUT",
        "STRAVA",
        "MANUAL",
        "IMPORT"
    ]
}

/// One row in the Source-Priority read-only matrix.
public struct SourcePriorityRow: Sendable, Equatable, Identifiable {
    public let metricKey: String
    public let label: String
    public let sources: [String]

    public var id: String {
        metricKey
    }

    public init(metricKey: String, label: String, sources: [String]) {
        self.metricKey = metricKey
        self.label = label
        self.sources = sources
    }

    /// Translates a wire-source token (`APPLE_HEALTH` / `WITHINGS` /
    /// `MANUAL` / `IMPORT`) to a human-readable German label. Shared with
    /// `WorkoutDetailView.sourceLabel(_:)` — both call sites match.
    public static func displayLabel(forSource raw: String) -> String {
        switch raw.uppercased() {
        case "APPLE_HEALTH": "Apple Health"
        case "WITHINGS": "Withings"
        case "WHOOP": "WHOOP"
        case "FITBIT": "Fitbit"
        case "STRAVA": "Strava"
        case "OURA": "Oura"
        case "POLAR": "Polar"
        case "NIGHTSCOUT": "Nightscout"
        case "MANUAL": "Manual"
        case "IMPORT": "Import"
        case "COMPUTED": "Computed"
        default: raw.capitalized
        }
    }

    /// SF Symbol for a wire-source token. Shared by the read-only settings
    /// display (`SettingsSourcesScreen`) and the reorder editor
    /// (`SourcePriorityEditorScreen`) so both render the same per-source glyph.
    public static func iconName(forSource raw: String) -> String {
        switch raw.uppercased() {
        case "APPLE_HEALTH": "heart.fill"
        case "WITHINGS": "scalemass.fill"
        case "WHOOP": "bolt.heart.fill"
        case "FITBIT": "figure.run"
        case "STRAVA": "figure.outdoor.cycle"
        case "OURA": "circle.circle.fill"
        case "POLAR": "heart.circle.fill"
        case "NIGHTSCOUT": "drop.fill"
        case "MANUAL": "hand.tap.fill"
        case "IMPORT": "square.and.arrow.down.fill"
        case "COMPUTED": "function"
        default: "circle.dashed"
        }
    }
}
