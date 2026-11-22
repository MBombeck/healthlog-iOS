import AppIntents
import WidgetKit

/// One choosable metric of the measurement widget. The list comes from the App
/// Group snapshot the app keeps current, so only metrics the person has data
/// for are offered, plus "Zuletzt erfasst", the choice the widget always had.
struct MeasurementMetricEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "widget.metric.type")
    static let defaultQuery = MeasurementMetricQuery()

    let id: String
    let title: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: symbol))
    }

    static var latest: MeasurementMetricEntity {
        MeasurementMetricEntity(
            id: WidgetMetricSelection.latestToken,
            title: String(localized: "widget.metric.latest"),
            symbol: "clock.arrow.circlepath"
        )
    }

    init(id: String, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }

    init(_ glance: WidgetSnapshot.MetricGlance) {
        self.init(id: glance.kindRaw, title: glance.title, symbol: glance.symbol)
    }
}

struct MeasurementMetricQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MeasurementMetricEntity] {
        let all = Self.available()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [MeasurementMetricEntity] {
        Self.available()
    }

    func defaultResult() async -> MeasurementMetricEntity? {
        .latest
    }

    private static func available() -> [MeasurementMetricEntity] {
        let glances = WidgetSnapshotStore().read()?.metricGlances ?? []
        return [.latest] + glances.map(MeasurementMetricEntity.init)
    }
}

/// The configuration of the measurement widget. No choice means "Zuletzt
/// erfasst", so a widget placed before the choice existed carries no value and
/// keeps showing what it showed.
struct MeasurementWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.latest_measurement.title"
    static let description = IntentDescription("widget.metric.description")

    @Parameter(title: "widget.metric.parameter")
    var metric: MeasurementMetricEntity?

    init() {}

    init(metric: MeasurementMetricEntity?) {
        self.metric = metric
    }

    /// The kind to resolve, `nil` for "Zuletzt erfasst".
    var choice: String? {
        guard let id = metric?.id, id != WidgetMetricSelection.latestToken else { return nil }
        return id
    }
}
