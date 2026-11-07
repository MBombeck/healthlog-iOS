import Foundation
import Observation

/// **Local Doctor Report Store (T-7 + v0.6.0 H.6 co-emit).**
///
/// View-facing facade that orchestrates the spec-builder + renderer
/// pipeline. Reads the live stores from the @MainActor side, builds a
/// `DoctorReportSpec` snapshot, hands it to the renderer-actor, and
/// surfaces both the PDF URL **and** the FHIR R4 Document Bundle JSON
/// URL produced from the same snapshot (H.6 co-emit).
///
/// **Lifecycle / Cleanup:** when a new render lands, the previous PDF
/// + FHIR file are removed (mirrors the existing server-side
/// `DoctorReportStore`). `clearOnLogout()` removes any lingering
/// artifacts so a logout doesn't leak files into temp.
///
/// **Co-emit rationale:** the doctor flow always benefits from both
/// artifacts. The PDF is human-readable for the consult; the
/// `.fhir.json` is machine-importable into HAPI / Epic / Apple Health
/// Records. One tap → share-sheet with both files keeps the operator
/// surface single-action.
@MainActor
@Observable
public final class LocalDoctorReportStore {
    public private(set) var pdfURL: URL?
    public private(set) var fhirURL: URL?
    public private(set) var isWorking = false
    public private(set) var error: HLError?
    public var selection: DoctorReportSectionSelection = .all
    public var periodDays: Int = 90
    /// VISIT — a fixed window (already stopped at now) in place of the
    /// look-back of ``periodDays``; `nil` keeps the look-back.
    public var window: DateInterval?

    /// Returns the artifacts to hand to `ShareLink(items:)` — PDF first
    /// (operator-primary), FHIR second. Empty when nothing is generated.
    public var shareItems: [URL] {
        [pdfURL, fhirURL].compactMap { $0 }
    }

    private let renderer: DoctorReportRenderer
    private let measurementsStore: MeasurementsStore
    private let medicationsStore: MedicationsStore
    private let moodStore: MoodStore
    private let settingsStore: SettingsStore
    private var previousPDFURL: URL?
    private var previousFHIRURL: URL?
    private let calendar: Calendar
    private let now: () -> Date
    /// #115 · 1.2 — reads the server's per-medication adherence
    /// (`GET /api/medications/compliance`) when a report is generated. One
    /// request, user-initiated, never on the launch path. Tests inject a stub;
    /// `nil` result = unavailable (offline / standalone / old server).
    /// #126 P2 — asked with `?days=` = the report period, so the rows and the
    /// account figure cover the report's own window.
    @ObservationIgnored
    var complianceFetch: @MainActor (_ days: Int) async -> MedicationComplianceReport?
    /// #119 — the server's daily pulse for the report window (v1.40.1 rule).
    /// `nil` = unavailable; the pulse row then applies the rule to the readings.
    @ObservationIgnored
    var pulseDaysFetch: @MainActor (_ from: Date, _ to: Date) async -> [DailyPulseValue]?

    public init(
        renderer: DoctorReportRenderer = DoctorReportRenderer(),
        measurementsStore: MeasurementsStore,
        medicationsStore: MedicationsStore,
        moodStore: MoodStore,
        settingsStore: SettingsStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { .now }
    ) {
        self.renderer = renderer
        self.measurementsStore = measurementsStore
        self.medicationsStore = medicationsStore
        self.moodStore = moodStore
        self.settingsStore = settingsStore
        self.calendar = calendar
        self.now = now
        complianceFetch = { [medicationsStore] days in
            let repo = medicationsStore.repo
            return try? await repo.complianceReport(days: days)
        }
        pulseDaysFetch = { [measurementsStore] from, to in
            let repo = measurementsStore.repo
            return try? await repo.dailyPulse(from: from, to: to)
        }
    }

    /// Pulls a snapshot from the stores, builds the spec, renders the
    /// PDF, and updates `pdfURL`. Errors surface in `error` for the
    /// banner.
    public func generate(locale: ReportLocale = .de) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        let end = window?.end ?? now()
        let start = window?.start ?? calendar.date(byAdding: .day, value: -periodDays, to: end) ?? end
        let report = await complianceFetch(complianceDays(from: start))
        let pulseDays = await pulseDaysFetch(start, end)
        let snapshot = makeSnapshot(serverComplianceReport: report, serverPulseDays: pulseDays)
        let spec = DoctorReportSpecBuilder.build(
            snapshot: snapshot,
            periodStart: start,
            periodEnd: end,
            generatedAt: end,
            selection: selection,
            locale: locale,
            calendar: calendar
        )
        do {
            let renderedPDF = try await renderer.render(spec)
            let renderedFHIR = try DoctorReportFHIRWriter.write(spec: spec, generatedAt: end)
            if let prev = previousPDFURL {
                try? FileManager.default.removeItem(at: prev)
            }
            if let prev = previousFHIRURL {
                try? FileManager.default.removeItem(at: prev)
            }
            previousPDFURL = renderedPDF
            previousFHIRURL = renderedFHIR
            pdfURL = renderedPDF
            fhirURL = renderedFHIR
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    /// The compliance read takes whole days back from today: the look-back
    /// itself, or for a window the days its start lies back (at least one).
    func complianceDays(from start: Date) -> Int {
        guard window != nil else { return periodDays }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: now()).day ?? periodDays
        return max(1, days)
    }

    /// Reset all in-memory state on logout + remove the temp files.
    public func clearOnLogout() {
        if let url = pdfURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = fhirURL {
            try? FileManager.default.removeItem(at: url)
        }
        pdfURL = nil
        fhirURL = nil
        previousPDFURL = nil
        previousFHIRURL = nil
        error = nil
        selection = .all
        periodDays = 90
        window = nil
    }

    // MARK: - Snapshot

    func makeSnapshot(
        serverCompliance: [MedicationComplianceSummaryEntry]? = nil,
        serverComplianceReport: MedicationComplianceReport? = nil,
        serverPulseDays: [DailyPulseValue]? = nil
    ) -> DoctorReportSpecBuilder.Snapshot {
        let patientName: String = settingsStore.profile?.displayName
            ?? settingsStore.profile?.username
            ?? ""
        return DoctorReportSpecBuilder.Snapshot(
            patientName: patientName,
            fullName: settingsStore.profile?.fullName,
            insurerName: settingsStore.profile?.insurerName,
            insuranceNumber: settingsStore.profile?.insuranceNumber,
            insurerIkNumber: settingsStore.profile?.insurerIkNumber,
            appVersion: Self.appVersion(),
            measurements: measurementsStore.recent,
            medications: medicationsStore.medications,
            serverCompliance: serverCompliance,
            serverComplianceReport: serverComplianceReport,
            serverPulseDays: serverPulseDays,
            moodEntries: moodStore.entries,
            // #115 B5 — the PDF prints glucose in the account's unit.
            glucoseUnit: settingsStore.glucoseUnit,
            // #115 P2 — and weight / temperature / waist in the account's unit.
            accountUnits: settingsStore.unitPreferences
        )
    }

    private static func appVersion() -> String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Period presets

/// Days-window presets exposed on the export-screen picker. Matches the
/// shape the server-rendered report already uses so the UI
/// stays consistent.
public enum LocalDoctorReportPeriod: Int, CaseIterable, Identifiable, Sendable {
    case thirty = 30
    case sixty = 60
    case ninety = 90
    case oneEighty = 180
    case threeSixtyFive = 365

    public var id: Int {
        rawValue
    }

    public var label: String {
        switch self {
        case .thirty: "30T"
        case .sixty: "60T"
        case .ninety: "90T"
        case .oneEighty: "6M"
        case .threeSixtyFive: "1J"
        }
    }
}
