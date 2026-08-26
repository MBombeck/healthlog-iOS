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
    let onDismiss: () -> Void

    @State private var containerType: MedicationContainerType = .other
    @State private var unitsText: String = ""
    @State private var hasExpiry = false
    @State private var expiry: Date = .now
    @State private var isBusy = false
    @State private var confirmingDelete = false
    /// FORM-1 (Audit v0162) — drives the discard-confirmation dialog.
    @State private var showDiscardConfirm = false
    /// FORM-2 (Audit v0162) — initial focus onto the units field.
    @FocusState private var unitsFocused: Bool

    /// FORM-1 — baselines captured at init so a swipe-down only guards on a real
    /// change (register: the create defaults; correct: the item's values).
    private let initialContainerType: MedicationContainerType
    private let initialUnitsText: String
    private let initialHasExpiry: Bool
    private let initialExpiry: Date

    private var isEditing: Bool {
        item != nil
    }

    /// FORM-1 — any field diverges from its initial baseline.
    private var isDirty: Bool {
        containerType != initialContainerType
            || unitsText != initialUnitsText
            || hasExpiry != initialHasExpiry
            || (hasExpiry && expiry != initialExpiry)
    }

    init(
        medication: Medication,
        item: MedicationInventoryItemDTO?,
        onRegister: @escaping (MedicationInventoryCreate) async -> Void,
        onUpdate: @escaping (MedicationInventoryPatch) async -> Void,
        onDelete: @escaping () async -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.medication = medication
        self.item = item
        self.onRegister = onRegister
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        if let item {
            let seededType = item.containerType ?? .other
            let seededUnits = Self.unitString(item.unitsRemaining)
            let seededHasExpiry = item.printedExpiry != nil
            let seededExpiry = item.printedExpiry ?? .now
            _containerType = State(initialValue: seededType)
            _unitsText = State(initialValue: seededUnits)
            _hasExpiry = State(initialValue: seededHasExpiry)
            _expiry = State(initialValue: seededExpiry)
            initialContainerType = seededType
            initialUnitsText = seededUnits
            initialHasExpiry = seededHasExpiry
            initialExpiry = seededExpiry
        } else {
            // Register mode — the create defaults are the dirty baseline.
            initialContainerType = .other
            initialUnitsText = ""
            initialHasExpiry = false
            initialExpiry = .now
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HLSpace.lg) {
                    summaryCard
                    typeCard
                    unitsCard
                    expiryCard
                    if isEditing { lifecycleCard }
                    primaryButton
                    if isEditing { deleteButton }
                }
                .padding(.horizontal, HLSpace.lg)
                .padding(.top, HLSpace.lg)
                .padding(.bottom, HLSpace.xl)
            }
            .hlScreenBackground()
            .navigationTitle(Text(isEditing
                    ? "med.inventory.editor.title.edit"
                    : "med.inventory.editor.title.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "meds.quick.cancel")) {
                        if isDirty { showDiscardConfirm = true } else { onDismiss() }
                    }
                }
            }
            // FORM-2 — seed focus onto the units field once the sheet settles.
            .task {
                try? await Task.sleep(for: HLSheet.focusDelay)
                unitsFocused = true
            }
        }
        .hlSheetPresentation(.standard)
        .presentationBackground(HLColor.surface)
        // FORM-1 — guard against a swipe-down discarding unsaved edits; keep the
        // existing in-flight lock via `isBusy`.
        .hlDiscardGuard(isDirty: isDirty, isSaving: isBusy, isPresented: $showDiscardConfirm) {
            onDismiss()
        }
        .hlConfirmDestructive(
            Text("med.inventory.editor.delete.confirm.title"),
            isPresented: $confirmingDelete,
            confirm: Text(String(localized: "med.inventory.editor.delete.confirm.cta")),
            cancel: Text(String(localized: "meds.quick.cancel")),
            action: {
                Task {
                    isBusy = true
                    await onDelete()
                    isBusy = false
                }
            }
        )
    }

    private var summaryCard: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "shippingbox")
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
            Text(medication.dose.isEmpty
                ? medication.name
                : "\(medication.name) · \(medication.dose)")
                .font(.hlSubhead)
                .foregroundStyle(HLText.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typeCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("med.inventory.editor.type.label")
                Picker(
                    String(localized: "med.inventory.editor.type.label"),
                    selection: $containerType
                ) {
                    ForEach(MedicationContainerType.allCases) { type in
                        Label(type.localizedLabel, systemImage: type.glyph).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .tint(HLText.secondary)
                .accessibilityIdentifier("med.inventory.editor.type")
            }
        }
    }

    private var unitsCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel(isEditing
                    ? "med.inventory.editor.units.remaining.label"
                    : "med.inventory.editor.units.total.label")
                TextField(
                    String(localized: "med.inventory.editor.units.placeholder"),
                    text: $unitsText
                )
                .keyboardType(.decimalPad)
                .focused($unitsFocused)
                .font(.hlBody)
                .foregroundStyle(HLText.primary)
                .accessibilityIdentifier("med.inventory.editor.units")
                Text("med.inventory.editor.units.hint")
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
        }
    }

    private var expiryCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                Toggle(isOn: $hasExpiry) {
                    Text("med.inventory.editor.expiry.toggle")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                }
                .tint(HLText.secondary)
                if hasExpiry {
                    DatePicker(
                        String(localized: "med.inventory.editor.expiry.label"),
                        selection: $expiry,
                        displayedComponents: .date
                    )
                    .font(.hlSubhead)
                }
                // **B2 (server v1.33.0)** — state the rule that actually applies to
                // THIS container form. Pen / ampoule run the 30-days-after-opening
                // clock alongside the printed date; every other form expires on the
                // printed date alone. Copy only — the server computes `expiresAt`.
                Text(verbatim: containerType.localizedExpiryRule)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("med.inventory.editor.expiry.rule")
            }
        }
    }

    /// Edit-only lifecycle controls: mark first-use (start the in-use clock) +
    /// mark used-up (terminal).
    private var lifecycleCard: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                HLSectionLabel("med.inventory.editor.lifecycle.label")
                if item?.firstUseAt == nil {
                    Button {
                        Task {
                            isBusy = true
                            await onUpdate(MedicationInventoryPatch(markAsFirstUseAt: .set(.now)))
                            isBusy = false
                        }
                    } label: {
                        Label("med.inventory.editor.firstuse.cta", systemImage: "play.circle")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                } else {
                    // A7 — the server accepts an explicit `null` on
                    // `markAsFirstUseAt` to DELETE the first-use date, so a
                    // mis-tapped "als geöffnet markieren" is now undoable.
                    Button {
                        Task {
                            isBusy = true
                            await onUpdate(MedicationInventoryPatch(markAsFirstUseAt: .clear))
                            isBusy = false
                        }
                    } label: {
                        Label("med.inventory.editor.firstuse.clear.cta", systemImage: "arrow.uturn.backward.circle")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityIdentifier("med.inventory.editor.firstuse.clear")
                }
                Button {
                    Task {
                        isBusy = true
                        await onUpdate(MedicationInventoryPatch(markAsUsedUp: true))
                        isBusy = false
                    }
                } label: {
                    Label("med.inventory.editor.usedup.cta", systemImage: "checkmark.circle")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    private var primaryButton: some View {
        HLButton(
            String(localized: isEditing
                ? "med.inventory.editor.save.cta"
                : "med.inventory.editor.add.cta"),
            icon: "checkmark.circle.fill",
            variant: .restrained
        ) {
            Task { await commit() }
        }
        .disabled(isBusy || parsedUnits == nil)
        .accessibilityIdentifier("med.inventory.editor.commit")
    }

    private var deleteButton: some View {
        HLButton(
            String(localized: "med.inventory.editor.delete.cta"),
            variant: .destructive,
            size: .regular
        ) {
            confirmingDelete = true
        }
        .disabled(isBusy)
        .accessibilityIdentifier("med.inventory.editor.delete")
    }

    /// Parsed + clamped unit count, or nil when the field is empty / invalid.
    private var parsedUnits: Double? {
        guard let value = LocaleDecimalParser.parse(unitsText), value >= 0 else { return nil }
        let upper = isEditing ? Double(medicationInventoryUnitsCap) : Double(medicationInventoryUnitsCap)
        return min(value, upper)
    }

    private func commit() async {
        guard let units = parsedUnits else { return }
        isBusy = true
        defer { isBusy = false }
        let expiryValue = hasExpiry ? expiry : nil
        if isEditing {
            // M-1: when the user turns the expiry toggle OFF on a container that
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
                unitsTotal: max(1, units),
                containerType: containerType,
                printedExpiry: expiryValue,
                purchasedAt: nil,
                notes: nil
            ))
        }
    }

    /// `Double?` overload — an UNKNOWN (`nil`) remaining count (#31) seeds an
    /// EMPTY field, exactly like a corrupt one: the user types the real count
    /// rather than inheriting a fabricated `0`.
    nonisolated static func unitString(_ value: Double?) -> String {
        guard let value else { return "" }
        return unitString(value)
    }

    nonisolated static func unitString(_ value: Double) -> String {
        // **W-INVENTORY — editable-field pre-fill.** A corrupt remaining count
        // must never seed the field with a non-finite / negative / absurd value.
        // Unlike a read-only readout we cannot show "—" in a numeric field, so a
        // corrupt value seeds an EMPTY field (the user types the real count) —
        // never a fabricated 0 or wild number that the user might save back.
        guard let safe = InventorySanity.validUnits(value) else { return "" }
        if safe.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(safe))
        }
        return safe.formatted(.number.precision(.fractionLength(0 ... 2)))
    }
}
