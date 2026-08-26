// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    /// W-B180 — render verification for the medication card's due-state.
    ///
    /// The b179 future-due gate compared against the server SLOT instant, so a
    /// card whose dose window was already OPEN (now ≥ window start) but whose
    /// slot lay minutes ahead stayed neutral while the Live-Activity surface
    /// showed the dose as due. These tests render the REAL
    /// `ActiveMedicationRow` and assert the green "Jetzt fällig" treatment
    /// appears exactly from window start — and not before. Green is the ONLY
    /// hue on the card (`HLColor.statusOK` next-dose value), so a pixel
    /// hue-scan is a stable signal.
    ///
    /// **09-15 — the clock is injected, not observed.** These fixtures used to
    /// be anchored on `.now` and then flattened into `TimeOfDay`, throwing the
    /// date away; near midnight the derived window and the derived slot landed
    /// on different calendar days and the suite went red for reasons that had
    /// nothing to do with what it was testing (09-01 reproduced exactly that at
    /// 23:55 and the same tree green at 00:35). Every case now names the
    /// instant it renders at, so the suite gives the same verdict at any
    /// wall-clock minute — including the two that used to disagree.
    ///
    /// Set `MED_RENDER_DIR=/tmp/b180` to export the rendered PNGs.
    @MainActor
    @Suite("MedicationCard — W-B180 due-state render", .serialized)
    struct MedicationDueNowRenderTests {
        // MARK: - Fixtures (anchored on an instant the test names)

        /// A wall-clock instant on the fixed reference Wednesday, 2026-05-20,
        /// read in the SAME calendar the card's reducer defaults to.
        private func instant(dayOffset: Int = 0, hour: Int, minute: Int) -> Date {
            Calendar.current.date(from: DateComponents(
                year: 2026,
                month: 5,
                day: 20 + dayOffset,
                hour: hour,
                minute: minute
            )) ?? .distantPast
        }

        /// Daily med whose window opened `openedMinutesAgo` before `now` and
        /// whose server slot (`nextDueAt`) sits `slotInMinutes` after it.
        private func med(now: Date, openedMinutesAgo: Int, slotInMinutes: Int) -> Medication {
            let calendar = Calendar.current
            let windowStart = calendar.date(
                byAdding: .minute, value: -openedMinutesAgo, to: now
            ) ?? now
            let windowEnd = calendar.date(byAdding: .minute, value: 180, to: windowStart) ?? now
            let slot = calendar.date(byAdding: .minute, value: slotInMinutes, to: now) ?? now
            let startC = calendar.dateComponents([.hour, .minute], from: windowStart)
            let endC = calendar.dateComponents([.hour, .minute], from: windowEnd)
            let slotC = calendar.dateComponents([.hour, .minute], from: slot)
            let start = TimeOfDay(hour: startC.hour ?? 0, minute: startC.minute ?? 0)
            let end = TimeOfDay(hour: endC.hour ?? 0, minute: endC.minute ?? 0)
            let time = TimeOfDay(hour: slotC.hour ?? 0, minute: slotC.minute ?? 0)
            let entry = ScheduleEntry(
                cadence: .daily,
                timesOfDay: [time],
                windowStart: start,
                windowEnd: end,
                doseWindows: [MedicationDoseWindowDTO(
                    timeOfDay: String(format: "%02d:%02d", time.hour, time.minute),
                    start: String(format: "%02d:%02d", start.hour, start.minute),
                    end: String(format: "%02d:%02d", end.hour, end.minute)
                )]
            )
            return Medication(
                id: "med-b180-render",
                name: "Lisinopril",
                dose: "5 mg",
                schedule: MedicationSchedule(entries: [entry]),
                todayEventCount: 0,
                active: true,
                nextDueAt: slot
            )
        }

        /// 09-15 — a daily 23:00 dose whose row publishes a declared
        /// `23:00–02:00` on-time window, with the un-served 23:00 slot as
        /// `nextDueAt` (the shape the server publishes for a due, untaken dose,
        /// pinned by `W-B179 (b)`), so the future-due gate never fires and the
        /// verdict is the local band arithmetic's alone.
        private func overnightMed() -> Medication {
            let entry = ScheduleEntry(
                cadence: .daily,
                timesOfDay: [TimeOfDay(hour: 23, minute: 0)],
                windowStart: TimeOfDay(hour: 23, minute: 0),
                windowEnd: TimeOfDay(hour: 2, minute: 0),
                doseWindows: [MedicationDoseWindowDTO(
                    timeOfDay: "23:00",
                    start: "23:00",
                    end: "02:00"
                )]
            )
            return Medication(
                id: "med-b180-render-overnight",
                name: "Lisinopril",
                dose: "5 mg",
                schedule: MedicationSchedule(entries: [entry]),
                todayEventCount: 0,
                active: true,
                nextDueAt: instant(hour: 23, minute: 0)
            )
        }

        private func render(_ medication: Medication, at now: Date, name: String) throws -> UIImage {
            let view = ScrollView {
                MedicationCard(
                    medication: medication,
                    displayState: .from(medication: medication),
                    scheduleSummary: "1× täglich",
                    compliance: nil,
                    lastTakenAt: nil,
                    onHistory: {},
                    onComplianceTap: {},
                    onEdit: {},
                    onMarkTaken: {},
                    onMarkSkipped: {},
                    onArchive: {},
                    now: now
                )
                .padding()
            }
            .background(HLSurface.primary)
            let size = CGSize(width: 393, height: 500)
            let host = UIHostingController(rootView: AnyView(view))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            {
                window.windowScene = scene
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if let dir = ProcessInfo.processInfo.environment["MED_RENDER_DIR"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try image.pngData()?.write(to: url)
            }
            window.isHidden = true
            return image
        }

        /// `true` when the image carries a clearly GREEN pixel — the
        /// `HLColor.statusOK` "Jetzt fällig" value is the only green on the
        /// card (monochrome doctrine everywhere else).
        private func hasGreenInk(_ image: UIImage) -> Bool {
            guard let source = image.cgImage else { return false }
            // The renderer's native buffer varies (BGRA, wide-colour 16-bit
            // channels, …) — redraw into a KNOWN RGBA8888 context so the
            // byte layout is unambiguous before scanning.
            let width = source.width
            let height = source.height
            let bpr = width * 4
            var buffer = [UInt8](repeating: 0, count: bpr * height)
            guard let ctx = CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Require a CLUSTER of green pixels: the "Jetzt fällig" glyphs
            // carry hundreds, while text anti-aliasing fringes on a neutral
            // card only produce a handful of slightly-tinted edge pixels.
            var greenCount = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let p = y * bpr + x * 4
                    let r = Int(buffer[p])
                    let g = Int(buffer[p + 1])
                    let b = Int(buffer[p + 2])
                    if g > 70, g > r + 20, g > b + 20 {
                        greenCount += 1
                        if greenCount >= 20 { return true }
                    }
                }
            }
            return false
        }

        // MARK: - Tests

        @Test("window open, slot still ahead → green 'Jetzt fällig' paints")
        func inWindowBeforeSlotPaintsGreen() throws {
            // Window opened 30 min ago, server slot in 30 min — the b179
            // slot-instant gate rendered this neutral.
            let now = instant(hour: 10, minute: 0)
            let medication = med(now: now, openedMinutesAgo: 30, slotInMinutes: 30)
            #expect(MedicationWindowStatus.reduce(medication: medication, now: now) == .inWindow)
            let image = try render(medication, at: now, name: "med-due-in-window")
            #expect(hasGreenInk(image), "due-now value must paint in statusOK green")
        }

        @Test("window not yet open → neutral card, no green")
        func beforeWindowStaysNeutral() throws {
            // Window opens in 60 min (slot in 90) — neutral "Heute, HH:MM".
            let now = instant(hour: 10, minute: 0)
            let medication = med(now: now, openedMinutesAgo: -60, slotInMinutes: 90)
            #expect(MedicationWindowStatus.reduce(medication: medication, now: now) == nil)
            let image = try render(medication, at: now, name: "med-due-pre-window")
            #expect(!hasGreenInk(image), "pre-window card must stay neutral")
        }

        @Test("declared 23:00–02:00 window paints green after midnight")
        func midnightCrossingWindowPaintsGreenAfterMidnight() throws {
            // 00:35, 85 minutes before the declared window closes. This is the
            // hour a user is most likely to be taking a late medication, and
            // the card rendered neutral because the reducer had substituted a
            // 22:00–23:59 band for the declared 23:00–02:00 one.
            let now = instant(dayOffset: 1, hour: 0, minute: 35)
            let image = try render(overnightMed(), at: now, name: "med-due-past-midnight")
            #expect(
                hasGreenInk(image),
                "EXPECTED_RED: the post-midnight half of an open dose window renders neutral"
            )
        }

        @Test("declared 23:00–02:00 window stays neutral before it opens")
        func midnightCrossingWindowStaysNeutralBeforeItOpens() throws {
            // 22:15 — the control for the case above. The substituted ±60 band
            // opened 45 minutes early; the declared one has not opened at all.
            let now = instant(hour: 22, minute: 15)
            let image = try render(overnightMed(), at: now, name: "med-due-pre-midnight-window")
            #expect(
                !hasGreenInk(image),
                "EXPECTED_RED: a declared window that has not opened renders due-now"
            )
        }
    }
#endif
