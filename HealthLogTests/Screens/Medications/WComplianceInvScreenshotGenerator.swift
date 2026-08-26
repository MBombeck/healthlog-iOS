import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// **W-COMPLIANCE-INV render-verify generator.** Renders the two fixed
/// surfaces with deterministic fixtures via `ImageRenderer` and writes PNGs
/// to `COMPINV_OUT` (default `/tmp/compinv`) — the committed
/// `ComplianceHeatmapWindowScreenshotGenerator` pattern (the live surfaces
/// need a logged-in session; a fixture render is the honest pixel artefact
/// of the shipped layout).
///
/// Task 1 evidence — the KPI load progression that used to flicker
/// 100 → 60 → 50 now paints: placeholder → server value (one numeric paint):
///   - `kpi-1-pending.png` — em-dash placeholder while the fetch is pending,
///   - `kpi-2-server.png` — the server-canonical (ledger) number,
///   - `kpi-3-offline-fallback.png` — the clearly-marked local estimate,
///   - `card-1-pending-skeleton.png` / `card-2-server.png` — same contract
///     on the medication card's compliance bars.
///
/// Task 2 evidence — generic inventory for a NON-GLP-1 (tablet) medication:
///   - `inventory-tablet.png`.
@MainActor
@Suite("W-COMPLIANCE-INV screenshot generator")
struct WComplianceInvScreenshotGenerator {
    private var outDir: URL {
        if let override = ProcessInfo.processInfo.environment["COMPINV_OUT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/compinv", isDirectory: true)
    }

    private func write(_ view: some View, name: String) {
        let host = view
            .frame(width: 393)
            .padding(HLSpace.lg)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }

    @Test("generate W-COMPLIANCE-INV screenshots")
    func generateScreenshots() {
        // — Task 1: KPI load progression —
        write(
            ComplianceKPISection(state: .pending),
            name: "kpi-1-pending"
        )
        write(
            ComplianceKPISection(state: .server(.init(inTime: 14, total: 28))),
            name: "kpi-2-server"
        )
        write(
            ComplianceKPISection(state: .localFallback(.init(inTime: 14, total: 28))),
            name: "kpi-3-offline-fallback"
        )

        // — Task 1: medication-card compliance bars —
        write(makeCard(compliance: nil), name: "card-1-pending-skeleton")
        write(
            makeCard(compliance: .init(
                rate7: 86,
                rate30: 92,
                displayShortDays: 7,
                displayShortRate: 86,
                displayLongDays: 30,
                displayLongRate: 92
            )),
            name: "card-2-server"
        )

        // — Task 2: generic inventory, NON-GLP-1 tablet medication —
        write(
            MedicationInventorySection(
                medication: Medication(
                    id: "med-lisinopril",
                    name: "Lisinopril",
                    dose: "5 mg",
                    schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
                ),
                items: tabletInventory(),
                runwayDays: nil,
                onEdit: { _ in },
                onRegister: {}
            ),
            name: "inventory-tablet"
        )

        let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []
        #expect(files.contains("kpi-1-pending.png"))
        #expect(files.contains("kpi-2-server.png"))
        #expect(files.contains("kpi-3-offline-fallback.png"))
        #expect(files.contains("card-1-pending-skeleton.png"))
        #expect(files.contains("card-2-server.png"))
        #expect(files.contains("inventory-tablet.png"))
    }

    // MARK: - Fixtures

    private func makeCard(compliance: MedicationsStore.ComplianceCardSnapshot?) -> some View {
        let med = Medication(
            id: "med-lisinopril",
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "BLOOD_PRESSURE",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        return MedicationCard(
            medication: med,
            displayState: .from(medication: med),
            scheduleSummary: "Täglich · 08:00",
            compliance: compliance,
            lastTakenAt: nil,
            onHistory: {},
            onComplianceTap: {},
            onEdit: {},
            onMarkTaken: {},
            onMarkSkipped: {},
            onArchive: {}
        )
    }

    private func tabletInventory() -> [MedicationInventoryItemDTO] {
        let day: TimeInterval = 24 * 60 * 60
        return [
            MedicationInventoryItemDTO(
                id: "inv-1",
                userId: "u-1",
                medicationId: "med-lisinopril",
                state: "IN_USE",
                unitsTotal: 30,
                unitsRemaining: 12,
                firstUseAt: Date(timeIntervalSinceNow: -18 * day),
                expiresAt: Date(timeIntervalSinceNow: 200 * day)
            ),
            MedicationInventoryItemDTO(
                id: "inv-2",
                userId: "u-1",
                medicationId: "med-lisinopril",
                state: "ACTIVE",
                unitsTotal: 30,
                unitsRemaining: 30,
                printedExpiry: Date(timeIntervalSinceNow: 380 * day)
            ),
            MedicationInventoryItemDTO(
                id: "inv-3",
                userId: "u-1",
                medicationId: "med-lisinopril",
                state: "USED_UP",
                unitsTotal: 30,
                unitsRemaining: 0
            )
        ]
    }
}
