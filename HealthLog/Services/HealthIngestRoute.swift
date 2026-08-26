/// Canonical server paths for the two HealthKit ingest families consumed by
/// the app. This deliberately stays narrow: endpoint-specific query and body
/// construction remains in the owning repositories.
enum HealthIngestRoute {
    static let workoutsBatch = "/api/workouts/batch"

    static let ecgIngest = "/api/insights/ecg"
    static let ecgList = ecgIngest

    static func ecgDetail(id: String) -> String {
        "\(ecgList)/\(id)"
    }
}
