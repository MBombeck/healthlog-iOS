import SwiftUI

/// **Generic per-medication supply (web "Bestand" tab parity, server
/// v1.16.10–.12).**
///
/// Renders the `GET /api/medications/[id]/inventory` item list for **every**
/// medication type — pen, vial, tablet pack, inhaler alike. The server route is
/// generic (ownership guard only, no GLP-1 gate).
///
/// **C1 (v1.16.10 wire rename):** items carry `unitsTotal` / `unitsRemaining`
/// (the endpoints "speak one wire dialect"). A container row's unit count is
/// divided by the medication's `unitsPerDose` to show the dose-equivalent
/// figure the web tab leads with. **C2:** every container is editable + a
/// register affordance is always present, with refetch after each write.
///
/// **C3 / ROUTE-06 (v1.37.19, plan 08-20).** The two *aggregate* supply
/// figures are the server's and only the server's:
/// ``Medication/stockDosesRemaining`` is the headline dose count — slot-aware,
/// divided server-side by the schedule-weighted average of each slot's
/// `resolvedUnitsPerDose`, which a single medication-level divisor cannot
/// reproduce — and ``Medication/runwayDays`` is the projection, from the same
/// burn rate the low-stock push evaluates, so the card and the notification
/// cannot disagree. Neither is recomputed here, and `nil` is never rounded up
/// into a guess: `nil` = tracking off / unknown → "—", `0` = tracked and
/// exhausted → a real zero.
struct MedicationInventorySection: View {
    let medication: Medication
    let items: [MedicationInventoryItemDTO]
    /// #25 / #115 · 1.3 — the server's `summary` from the same inventory GET
    /// (dose capacity, expired units). `nil` → the capacity reads "—".
    var summary: MedicationSupplySummary?
    /// The server's ``Medication/runwayDays`` **after** the display gate in
    /// ``runwayWithinThreshold(_:threshold:)`` — `nil` here means "do not
    /// render a runway row" (tracking off, or comfortably above the user's
    /// low-supply threshold), `0` means the supply is exhausted. Callers must
    /// pass the filtered value; the section applies no threshold of its own.
    var runwayDays: Int?
    /// Tap a container row to correct / mark / delete it (C2).
    var onEdit: (MedicationInventoryItemDTO) -> Void
    /// Register a new container (C2).
    var onRegister: () -> Void

    private var unitsPerDose: Double {
        medication.effectiveUnitsPerDose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            HStack {
                HLSectionLabel("med.inventory.section.header")
                Spacer(minLength: HLSpace.sm)
                Button(action: onRegister) {
                    Label("med.inventory.register.cta", systemImage: "plus")
                        .font(.hlCaption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HLText.secondary)
                .accessibilityIdentifier("medications.detail.inventory.register")
            }
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    summaryRow
                    if let runwayDays {
                        runwayRow(runwayDays)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: HLSpace.sm) {
                        ForEach(items) { item in
                            Button {
                                onEdit(item)
                            } label: {
                                itemRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("medications.detail.inventory")
    }

    /// Doses remaining — the **server's** `stockDosesRemaining`, never a local
    /// sum ÷ dose. The trailing "of Y" is the server's `summary.dosesTotal`
    /// (#25 / #115 · 1.3 — it used to be a local sum of `unitsTotal`); without a
    /// summary it reads "—". Units in expired containers get their own muted
    /// line, never folded into the headline.
    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
                Image(systemName: "shippingbox")
                    .font(.hlIcon(HLIconSize.md))
                    .foregroundStyle(HLText.secondary)
                Text(
                    String(
                        format: String(localized: "med.inventory.summary"),
                        Self.remainingDoseString(medication.stockDosesRemaining),
                        Self.capacityDoseString(summary)
                    )
                )
                .font(.hlHeadline)
                // (both figures collapse to "—" rather than to a fabricated 0)
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
            }
            if let expired = Self.expiredUnitsString(summary) {
                Text(String(format: String(localized: "med.inventory.expiredUnits"), expired))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
                    .accessibilityIdentifier("medications.detail.inventory.expired")
            }
        }
    }

    /// The server's dose capacity (`summary.dosesTotal`), "—" without one.
    nonisolated static func capacityDoseString(_ summary: MedicationSupplySummary?) -> String {
        guard let summary else { return InventorySanity.placeholder }
        return doseString(summary.dosesTotal, unitsPerDose: 1)
    }

    /// The server's `expiredUnits`, or `nil` when there are none to mention
    /// (or the value is not plausible).
    nonisolated static func expiredUnitsString(_ summary: MedicationSupplySummary?) -> String? {
        guard let units = summary?.expiredUnits, units > 0,
              InventorySanity.validUnits(units) != nil else { return nil }
        return doseString(units, unitsPerDose: 1)
    }

    /// C3 — the server's projected runway, already threshold-filtered.
    private func runwayRow(_ days: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.hlIcon(HLIconSize.sm))
                .foregroundStyle(HLColor.statusWarn)
            Text(
                String(
                    format: String(localized: "med.inventory.runway"),
                    days
                )
            )
            .font(.hlSubhead.weight(.medium))
            .foregroundStyle(HLColor.statusWarn)
            .monospacedDigit()
        }
        .accessibilityIdentifier("medications.detail.inventory.runway")
    }

    private func itemRow(_ item: MedicationInventoryItemDTO) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            if let type = item.containerType {
                Image(systemName: type.glyph)
                    .font(.hlIcon(HLIconSize.sm))
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityHidden(true)
            }
            Text(
                String(
                    format: String(localized: "med.inventory.item.doses"),
                    Self.doseString(item.unitsRemaining, unitsPerDose: unitsPerDose),
                    Self.doseString(item.unitsTotal, unitsPerDose: unitsPerDose)
                )
            )
            .font(.hlSubhead)
            .foregroundStyle(HLText.primary)
            .monospacedDigit()
            Spacer(minLength: HLSpace.sm)
            // **W-INVENTORY** — only render a plausible expiry date; a
            // sentinel / epoch timestamp is suppressed (never a fake "Jan 1970").
            if let expiry = InventorySanity.validDate(item.expiresAt ?? item.printedExpiry) {
                Text(expiry, format: .dateTime.day().month().year())
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            stateBadge(item.state)
            HLDisclosureChevron()
        }
        .contentShape(Rectangle())
    }

    /// Calm monochrome state badge — `EXPIRED` is the only signal colour
    /// (statusBad), matching the web's destructive badge.
    private func stateBadge(_ state: String) -> some View {
        Text(Self.stateLabel(state))
            .font(.hlCaption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(state == "EXPIRED" ? HLColor.statusBad : HLText.secondary)
            .padding(.horizontal, HLSpace.sm)
            .padding(.vertical, HLSpace.xxs)
            .overlay {
                Capsule().strokeBorder(HLText.tertiary.opacity(0.25), lineWidth: 1)
            }
            // Badge keeps its natural width so "In Gebrauch" never wraps to
            // two lines; the leading dose text yields space instead.
            .layoutPriority(1)
    }

    // MARK: - ROUTE-06 server supply truth (v1.37.19)

    /// Render the server's ``Medication/stockDosesRemaining`` headline.
    ///
    /// `nil` — inventory tracking is off, or the payload predates v1.37.19, or
    /// the value came from a cache blob written before the field existed — is
    /// the honest "we do not know" and renders `—`. `0` is a different answer
    /// ("tracked, and the supply ran out") and renders a real zero. A negative
    /// or absurd count is corrupt and also collapses to `—`; the client never
    /// substitutes a locally summed figure for a value the server withheld.
    nonisolated static func remainingDoseString(_ stockDosesRemaining: Int?) -> String {
        guard let stockDosesRemaining else { return InventorySanity.placeholder }
        guard let valid = InventorySanity.validCount(stockDosesRemaining) else {
            return InventorySanity.placeholder
        }
        return String(valid)
    }

    /// **A display gate, not a projection.** Filters the server's
    /// ``Medication/runwayDays`` through the mirrored `lowStockRunwayDays`
    /// preference and computes nothing.
    ///
    /// The two `nil`s in play mean different things and the distinction is the
    /// whole point of this function. The server's `runwayDays` is `nil` only
    /// when there is no projection to make (tracking off, or no consuming
    /// cadence — PRN / one-shot). The `nil` this returns additionally covers
    /// "there is a projection and it is comfortably above the threshold", which
    /// is the web's card behaviour: the runway surfaces once it crosses. Handing
    /// the raw server value straight to the runway row would put "≈ 340 Tage" on
    /// every well-stocked medication.
    ///
    /// `threshold == nil` = the low-supply alert is off, so nothing renders and
    /// nothing fires. `0` passes the gate (`0 <= threshold`) because an
    /// exhausted supply is precisely what the threshold exists to surface.
    ///
    /// The detail card and the local low-supply notification both call this, so
    /// the row a user sees and the alert they get key off the same crossing.
    nonisolated static func runwayWithinThreshold(_ serverRunwayDays: Int?, threshold: Int?) -> Int? {
        guard let threshold, let serverRunwayDays else { return nil }
        guard let days = InventorySanity.validCount(serverRunwayDays) else { return nil }
        return days <= threshold ? days : nil
    }

    /// Convert a unit count into a dose-equivalent string. With `unitsPerDose`
    /// 1 this is the raw integer; a fractional/multi-unit dose yields a trimmed
    /// decimal (e.g. 29.5 units ÷ 0.5 = 59 doses; 30 units ÷ 2 = 15 doses).
    /// `nonisolated` so unit tests can pin it off the MainActor.
    /// `Double?` overload — `nil` (a pre-validated-invalid sum) renders "—".
    nonisolated static func doseString(_ units: Double?, unitsPerDose: Double) -> String {
        guard let units else { return InventorySanity.placeholder }
        return doseString(units, unitsPerDose: unitsPerDose)
    }

    nonisolated static func doseString(_ units: Double, unitsPerDose: Double) -> String {
        // **W-INVENTORY — last-line display guard, central gate.** A corrupt
        // unit count (non-finite / negative / absurd) is NOT rendered as a
        // fabricated `0`; it renders the honest `—` placeholder instead
        // (operator brief: "nicht still auf 0 raten"). A degenerate
        // `unitsPerDose` falls back to 1 (a missing per-dose conversion is not
        // itself corrupt supply data). The dose-equivalent is validated again
        // so a division can never re-introduce an absurd result.
        guard let validUnits = InventorySanity.validUnits(units) else {
            return InventorySanity.placeholder
        }
        let divisor = unitsPerDose.isFinite && unitsPerDose > 0 ? unitsPerDose : 1
        guard let doses = InventorySanity.validUnits(validUnits / divisor) else {
            return InventorySanity.placeholder
        }
        if doses.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(doses))
        }
        return doses.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    /// Localized label for the server state enum; an unknown future literal
    /// renders verbatim (tolerant, never crashes the section). `nonisolated`
    /// so unit tests can pin it off the MainActor.
    nonisolated static func stateLabel(_ state: String) -> String {
        switch state {
        case "ACTIVE": String(localized: "med.inventory.state.active")
        case "IN_USE": String(localized: "med.inventory.state.in_use")
        case "EXPIRED": String(localized: "med.inventory.state.expired")
        case "USED_UP": String(localized: "med.inventory.state.used_up")
        default: state
        }
    }
}
