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
    }

    /// Pulls a snapshot from the stores, builds the spec, renders the
    /// PDF, and updates `pdfURL`. Errors surface in `error` for the
    /// banner.
    public func generate(locale: ReportLocale = .de) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        let snapshot = makeSnapshot()
        let end = now()
        let start = calendar.date(byAdding: .day, value: -periodDays, to: end) ?? end
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
    }

    // MARK: - Snapshot

    func makeSnapshot() -> DoctorReportSpecBuilder.Snapshot {
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
            compliance: medicationsStore.compliance,
            intakes: medicationsStore.todayIntakes,
            moodEntries: moodStore.entries
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
