import SwiftUI

/// **C2 (server v1.16.10–.12) — generic supply editor for every medication.**
///
/// Two modes:
///   - **Register** (`item == nil`): pick a container type + set the total unit
///     count + optional printed-expiry, POST `createInventoryItemSchema`.
///   - **Correct** (`item != nil`): absolute remaining-unit correction
///     (`unitsRemaining`), mark first-use, mark used-up, edit printed-expiry,
///     delete. PATCH / DELETE `updateInventoryItemSchema`.
///
/// All write semantics (decrement, state machine, expiry clocks, refund) are
/// server-authoritative — the sheet only posts user intent and the host
/// refetches the list. Units are shown raw (the dose-equivalent conversion is
/// the read-card's job; correcting stock is a unit-level operation).
struct MedicationSupplyEditorSheet: View {
    let medication: Medication
    /// `nil` → register a new container; non-nil → correct an existing one.
    let item: MedicationInventoryItemDTO?

    /// Register intent.
    let onRegister: (MedicationInventoryCreate) async -> Void
    /// Correct intent (absolute remaining + flags).
    let onUpdate: (MedicationInventoryPatch) async -> Void
    /// Delete intent.
    let onDelete: () async -> Void

    @State private var containerType: MedicationContainerType = .other
    /// The unit count; `nil` while the field holds nothing usable.
    @State private var units: Double?
    @State private var unitsState: HLNumberEntry.State = .empty
    @State private var hasExpiry = false
    @State private var expiry: Date = .now
    @State private var isBusy = false

    /// Baselines captured at init so a swipe-down only guards on a real
    /// change (register: the create defaults; correct: the item's values).
    private let initialContainerType: MedicationContainerType
    private let initialUnits: Double?
    private let initialHasExpiry: Bool
    private let initialExpiry: Date

    private var isEditing: Bool {
        item != nil
    }

    /// Any field diverges from its initial baseline.
    private var isDirty: Bool {
        containerType != initialContainerType
            || units != initialUnits
            || hasExpiry != initialHasExpiry
            || (hasExpiry && expiry != initialExpiry)
    }

    init(
        medication: Medication,
        item: MedicationInventoryItemDTO?,
        onRegister: @escaping (MedicationInventoryCreate) async -> Void,
        onUpdate: @escaping (MedicationInventoryPatch) async -> Void,
        onDelete: @escaping () async -> Void
    ) {
        self.medication = medication
        self.item = item
        self.onRegister = onRegister
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        if let item {
            let seededType = item.containerType ?? .other
            let seededUnits = item.unitsRemaining.flatMap(InventorySanity.validUnits)
            let seededHasExpiry = item.printedExpiry != nil
            let seededExpiry = item.printedExpiry ?? .now
            _containerType = State(initialValue: seededType)
            _units = State(initialValue: seededUnits)
            _hasExpiry = State(initialValue: seededHasExpiry)
            _expiry = State(initialValue: seededExpiry)
            initialContainerType = seededType
            initialUnits = seededUnits
            initialHasExpiry = seededHasExpiry
            initialExpiry = seededExpiry
        } else {
            // Register mode — the create defaults are the dirty baseline.
            initialContainerType = .other
            initialUnits = nil
            initialHasExpiry = false
            initialExpiry = .now
        }
    }

    var body: some View {
        HLSheetScaffold(
            isEditing ? "med.inventory.editor.title.edit" : "med.inventory.editor.title.add",
            size: .standard,
            action: isEditing
                ? .save(isEnabled: Self.canSave(units: units) && !isBusy) { await commit() }
                : .add(isEnabled: Self.canSave(units: units) && !isBusy) { await commit() },
            isDirty: isDirty
        ) {
            HLPage {
                summaryCard
                typeCard
                unitsCard
                expiryCard
                if isEditing {
                    lifecycleCard
                    // Deleting a container is not undoable: it asks first.
                    HLDeleteButton(
                        "med.inventory.editor.delete.cta",
                        form: .page,
                        action: .confirmed(title: "med.inventory.editor.delete.confirm.title") {
                            isBusy = true
                            await onDelete()
                            isBusy = false
                        }
                    )
                    .disabled(isBusy)
                    .accessibilityIdentifier("med.inventory.editor.delete")
                }
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "shippingbox")
                .hlText(.footnote)
                .accessibilityHidden(true)
            Text(medication.dose.isEmpty
                ? medication.name
                : "\(medication.name), \(medication.dose)")
                .hlText(.factLabel)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLCardLabel("med.inventory.editor.type.label")
                if let unnameable = Self.unnameableTypeLabel(for: item?.containerType) {
                    Label(unnameable, systemImage: MedicationContainerType.unknown.glyph)
                        .font(.hlBody)
                        .foregroundStyle(HLText.secondary)
                        .accessibilityIdentifier("med.inventory.editor.type.unnameable")
                } else {
                    Picker(selection: $containerType) {
                        ForEach(MedicationContainerType.serverCases) { type in
                            Label(type.localizedLabel, systemImage: type.glyph).tag(type)
                        }
                    } label: {
                        HLRowTitle("med.inventory.editor.type.label")
                    }
                    .pickerStyle(.menu)
                    .tint(HLText.secondary)
                    .accessibilityIdentifier("med.inventory.editor.type")
                }
            }
        }
    }

    /// **Audit B-4 (fix round 1) — the container form the card has to STATE,
    /// because it cannot offer it.**
    ///
    /// The picker enumerates ``MedicationContainerType/serverCases``, which
    /// deliberately excludes the decode-only sentinel, so a menu picker seeded
    /// with a form this build cannot name had no tag matching its selection and
    /// rendered a BLANK current value: the one screen where the sentinel's new
    /// label would help was the one screen that hid it.
    ///
    /// Answering with the label instead of a control costs nothing here — the
    /// edit branch sends ``MedicationInventoryPatch``, which carries no
    /// `containerType` at all, so the picker in correct-mode was already
    /// decorative. Register-mode starts at ``MedicationContainerType/other`` and
    /// can only be moved through `serverCases`, so it never reaches this arm.
    ///
    /// `nil` — the picker renders the seeded form itself — for every nameable
    /// form and for a row that carries none (a ≤v1.16.9 payload).
    nonisolated static func unnameableTypeLabel(for type: MedicationContainerType?) -> String? {
        type == .unknown ? MedicationContainerType.unknown.localizedLabel : nil
    }

    /// A new container holds at least one unit, a correction may reach
    /// zero; neither goes past the cap. Outside the range the field says so
    /// and saving waits.
    nonisolated static func unitsRange(isEditing: Bool) -> ClosedRange<Double> {
        (isEditing ? 0 : 1) ... Double(medicationInventoryUnitsCap)
    }

    /// Saving needs a unit count the field took.
    nonisolated static func canSave(units: Double?) -> Bool {
        units != nil
    }

    /// The count of units, never of doses. Saving waits for a valid number.
    private var unitsCard: some View {
        HLCard {
            HLNumberField(
                isEditing
                    ? "med.inventory.editor.units.remaining.label"
                    : "med.inventory.editor.units.total.label",
                value: $units,
                state: $unitsState,
                unit: .plain,
                range: Self.unitsRange(isEditing: isEditing),
                fractionDigits: 0 ... 2
            )
            .accessibilityIdentifier("med.inventory.editor.units")
        }
    }

    private var expiryCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Toggle(isOn: $hasExpiry) {
                    HLRowTitle("med.inventory.editor.expiry.toggle")
                }
                .tint(HLText.secondary)
                if hasExpiry {
                    DatePicker(
                        selection: $expiry,
                        displayedComponents: .date
                    ) {
                        HLRowTitle("med.inventory.editor.expiry.label")
                    }
                    .font(.hlSubhead)
                }
                // **B2 (server v1.33.0)** — state the rule that actually applies to
                // THIS container form. Pen / ampoule run the 30-days-after-opening
                // clock alongside the printed date. Copy only — the server
                // computes `expiresAt`. Every other form expires on the
                // printed date alone, which the date picker already says, so the
                // line appears only for the first-use clock.
                if containerType.usesFirstUseExpiryClock {
                    Text(verbatim: containerType.localizedExpiryRule)
                        .hlText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("med.inventory.editor.expiry.rule")
                }
            }
        }
    }

    /// Edit-only lifecycle controls: mark first-use (start the in-use clock) +
    /// mark used-up (terminal).
    private var lifecycleCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLCardLabel("med.inventory.editor.lifecycle.label")
                if item?.firstUseAt == nil {
                    HLLinkButton("med.inventory.editor.firstuse.cta", systemImage: "play.circle", alignment: .leading) {
                        update(MedicationInventoryPatch(markAsFirstUseAt: .set(.now)))
                    }
                    .disabled(isBusy)
                } else {
                    // The server accepts an explicit `null` on
                    // `markAsFirstUseAt` to DELETE the first-use date, so a
                    // mis-tapped "als geöffnet markieren" is now undoable.
                    HLLinkButton(
                        "med.inventory.editor.firstuse.clear.cta",
                        systemImage: "arrow.uturn.backward.circle",
                        alignment: .leading
                    ) {
                        update(MedicationInventoryPatch(markAsFirstUseAt: .clear))
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("med.inventory.editor.firstuse.clear")
                }
                HLLinkButton("med.inventory.editor.usedup.cta", systemImage: "checkmark.circle", alignment: .leading) {
                    update(MedicationInventoryPatch(markAsUsedUp: true))
                }
                .disabled(isBusy)
            }
        }
    }

    /// Runs one lifecycle patch with the sheet busy while it is out.
    private func update(_ patch: MedicationInventoryPatch) {
        Task {
            isBusy = true
            await onUpdate(patch)
            isBusy = false
        }
    }

    /// Hands the input to the host; the sheet closes once it went out.
    private func commit() async -> Bool {
        guard let units else { return false }
        isBusy = true
        defer { isBusy = false }
        let expiryValue = hasExpiry ? expiry : nil
        if isEditing {
            // When the user turns the expiry toggle OFF on a container that
            // had one, send an explicit clear (JSON `null`) so the server actually
            // removes it. Omitting the key means "unchanged" and the old expiry
            // would survive — hence the tri-state `RecordPatchField`, not an
            // `Optional` that collapses both intents into `nil`.
            let mustClearExpiry = !hasExpiry && item?.printedExpiry != nil
            let expiryField: RecordPatchField<Date> = if let expiryValue {
                .set(expiryValue)
            } else if mustClearExpiry {
                .clear
            } else {
                .unchanged
            }
            await onUpdate(MedicationInventoryPatch(
                printedExpiry: expiryField,
                unitsRemaining: units
            ))
        } else {
            await onRegister(MedicationInventoryCreate(
                unitsTotal: units,
                containerType: containerType,
                printedExpiry: expiryValue,
                purchasedAt: nil,
                notes: nil
            ))
        }
        return true
    }

    /// `Double?` overload — an UNKNOWN (`nil`) remaining count seeds an
    /// EMPTY field, exactly like a corrupt one: the user types the real count
    /// rather than inheriting a fabricated `0`.
    nonisolated static func unitString(_ value: Double?) -> String {
        guard let value else { return "" }
        return unitString(value)
    }

    nonisolated static func unitString(_ value: Double) -> String {
        // **Editable-field pre-fill.** A corrupt remaining count
        // must never seed the field with a non-finite / negative / absurd value.
        // Unlike a read-only readout we cannot show "—" in a numeric field, so a
        // corrupt value seeds an EMPTY field (the user types the real count) —
        // never a fabricated 0 or wild number that the user might save back.
        guard let safe = InventorySanity.validUnits(value) else { return "" }
        if safe.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(safe))
        }
        return HLValueFormat.number(safe, fractionDigits: 0 ... 2)
    }
}
