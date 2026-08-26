import Foundation

// MARK: - Local doctor-report builder

public extension AppContainer {
    /// T-7 — Lifted out of `init` to keep `AppContainer` under
    /// `type_body_length` / `file_length` swiftlint ceilings. Builds the
    /// on-device, server-bypassing PDF report store from the four store
    /// dependencies it needs: measurements (vitals / charts), medications
    /// (intake history + GLP-1 stack), mood (timeline), settings (units /
    /// locale).
    static func buildLocalDoctorReport(
        _ measurementsStore: MeasurementsStore,
        _ medicationsStore: MedicationsStore,
        _ moodStore: MoodStore,
        _ settingsStore: SettingsStore
    ) -> LocalDoctorReportStore {
        LocalDoctorReportStore(
            measurementsStore: measurementsStore,
            medicationsStore: medicationsStore,
            moodStore: moodStore,
            settingsStore: settingsStore
        )
    }
}
