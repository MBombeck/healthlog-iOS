import AppIntents
import Foundation

/// **1.5 SHORTCUT (#155, public #1295)** — one of the person's own metrics
/// as an App-Intents entity, so Shortcuts, Siri and the Action button can pick
/// it by name.
///
/// Carries what the intent needs without a second read: the name to speak
/// back, the unit to show beside the value and the metric's `decimals` to
/// round to. The target band stays out on purpose: it is the person's own
/// "good range", not a limit a value has to fit (see `CustomMetricDTO`).
struct CustomMetricEntity: AppEntity {
    let id: String
    /// Empty when the id could not be matched against any list we have, see
    /// ``CustomMetricEntityQuery/entities(for:)``.
    let name: String
    let unit: String
    let decimals: Int?

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Custom metric"
    )

    static let defaultQuery = CustomMetricEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        guard name.isEmpty == false else {
            return DisplayRepresentation(title: "Custom metric")
        }
        guard unit.isEmpty == false else {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(unit)")
    }

    init(id: String, name: String, unit: String, decimals: Int?) {
        self.id = id
        self.name = name
        self.unit = unit
        self.decimals = decimals
    }

    init(_ dto: CustomMetricDTO) {
        self.init(id: dto.id, name: dto.name, unit: dto.unit, decimals: dto.decimals)
    }
}

/// Resolves ``CustomMetricEntity`` values: suggestions for the picker, a
/// search by name, and the lookup by id when a saved shortcut runs.
///
/// **Offline.** The list comes from `CustomMetricsRepository.customMetrics()`
/// (SWR cache-first). When that read fails, the last cached list answers, so a
/// shortcut built at home still runs in a dead spot. Signed out, the picker
/// offers nothing; a saved shortcut still resolves (see
/// ``entities(for:)``) so the intent's own gate can say "sign in first".
struct CustomMetricEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [CustomMetricEntity] {
        let deps = IntentDependencies.resolve()
        var known: [CustomMetricEntity] = []
        if IntentDependencies.isSignedIn(deps), let list = try? await Self.catalog(deps) {
            known = list
        }
        // An id no list knows (signed out, offline before the first cached list,
        // or a metric deleted since the shortcut was built) still resolves, with
        // an empty name: the intent then says "sign in first", queues the value
        // offline or reports the 404. Dropping it here would end a saved
        // shortcut in a system error instead of a sentence the person can act on.
        return identifiers.map { id in
            known.first { $0.id == id } ?? CustomMetricEntity(id: id, name: "", unit: "", decimals: nil)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CustomMetricEntity] {
        try await suggestedEntities().filter { Self.matches($0.name, query: string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [CustomMetricEntity] {
        let deps = IntentDependencies.resolve()
        guard IntentDependencies.isSignedIn(deps) else { return [] }
        return try await Self.catalog(deps)
    }

    /// Case- and diacritic-insensitive substring match, trimmed. An empty
    /// query matches everything. Pure, so it is testable without Siri.
    nonisolated static func matches(_ name: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else { return true }
        return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The live list, or the cached one when the read fails. Rethrows only
    /// when neither exists.
    @MainActor
    private static func catalog(_ deps: IntentDependencies.Resolved) async throws -> [CustomMetricEntity] {
        let repo = deps.customMetricsRepo
        do {
            return try await repo.customMetrics().customMetrics.map(CustomMetricEntity.init)
        } catch {
            guard let cached = await repo.cachedCustomMetrics() else { throw error }
            return cached.customMetrics.map(CustomMetricEntity.init)
        }
    }
}
