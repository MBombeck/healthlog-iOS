import SwiftUI

// #1343 / #191 (server 1.49.0) — the watch's own figures on the workout
// detail: one card of rows like the splits card, a row only for a figure the
// server sends. Hidden for an older server and for a workout without any.

extension WorkoutDetailView {
    /// One figure as the card shows it: its catalog title and the value.
    struct PerformanceRow: Equatable, Identifiable {
        let title: LocalizedStringResource
        let value: String
        /// Stable identity and accessibility identifier suffix.
        let id: String
    }

    @ViewBuilder
    var performanceSection: some View {
        let rows = resolved.performance.map { Self.performanceRows($0) } ?? []
        if !rows.isEmpty {
            HLCard("workout.performance.title", layout: .rows) {
                ForEach(rows) { row in
                    HLRow(title: Text(row.title), value: Text(verbatim: row.value))
                        .accessibilityIdentifier("workout.performance.\(row.id)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workout.performance")
        }
    }

    /// The rows for the figures that are there, in the web's order: training
    /// effect, load, recovery, sweat loss, power, then the running dynamics.
    /// The server sends bounce in millimetres; it reads in centimetres here.
    nonisolated static func performanceRows(
        _ performance: WorkoutPerformanceDTO,
        locale: Locale = .current
    ) -> [PerformanceRow] {
        var rows: [PerformanceRow] = []
        func add(_ id: String, _ title: LocalizedStringResource, _ value: String?) {
            if let value { rows.append(PerformanceRow(title: title, value: value, id: id)) }
        }
        add("aerobic", "workout.performance.aerobicEffect", performance.aerobicTrainingEffect.map {
            HLValueFormat.number($0, fractionDigits: 1 ... 1, locale: locale)
        })
        add("anaerobic", "workout.performance.anaerobicEffect", performance.anaerobicTrainingEffect.map {
            HLValueFormat.number($0, fractionDigits: 1 ... 1, locale: locale)
        })
        add("load", "workout.performance.load", performance.trainingLoad.map {
            HLValueFormat.number($0, fractionDigits: 0 ... 0, locale: locale)
        })
        add("recovery", "workout.performance.recovery", performance.recoveryTimeMin.map {
            HLTimeFormat.duration($0 * 60, locale: locale)
        })
        add("sweat", "workout.performance.sweatLoss", performance.sweatLossMl.map {
            HLValueFormat.string($0, unit: .milliliters, fractionDigits: 0 ... 0, locale: locale)
        })
        add("power", "workout.performance.power", performance.avgPowerW.map {
            HLValueFormat.string($0, unit: .custom("W"), fractionDigits: 0 ... 0, locale: locale)
        })
        add("oscillation", "workout.performance.verticalOscillation", performance.avgVerticalOscillationMm.map {
            HLValueFormat.string($0 / 10, unit: .centimeters, fractionDigits: 1 ... 1, locale: locale)
        })
        add("groundContact", "workout.performance.groundContact", performance.avgGroundContactTimeMs.map {
            HLValueFormat.string($0, unit: .milliseconds, fractionDigits: 0 ... 0, locale: locale)
        })
        // The server sends the left foot's share; the web shows both feet.
        add("balance", "workout.performance.balance", performance.avgGroundContactBalancePct.map {
            let left = HLValueFormat.number($0, fractionDigits: 0 ... 1, locale: locale)
            let right = HLValueFormat.number(100 - $0, fractionDigits: 0 ... 1, locale: locale)
            return String(localized: "workout.performance.balanceValue \(left) \(right)", locale: locale)
        })
        return rows
    }
}
