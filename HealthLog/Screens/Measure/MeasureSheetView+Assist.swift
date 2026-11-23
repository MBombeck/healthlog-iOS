import SwiftUI

/// #191 QoL for the capture sheet, split out of `MeasureSheetView.swift` under
/// the file-length budget: the recent kinds as rows, the last reading with its
/// deviation hint, the glucose context default, "Save and next" and the save
/// receipt with Undo. The members it drives are non-private on the host for
/// this extension's reach.
extension MeasureSheetView {
    /// The kinds logged by hand, newest first, read from the person's own
    /// manual readings so every device agrees (web `recentEntryTypes`). Until
    /// the store holds any, this device's own MRU stands in, filtered to kinds
    /// the picker supports so a stale raw value can't surface a dead row.
    var recentKinds: [MetricKind] {
        let fromRows = MeasureRecentEntryKinds.kinds(from: store.recent, offered: supportedKinds)
        if !fromRows.isEmpty { return fromRows }
        return Array(MeasureRecentKinds.parse(recentKindsRaw, allowed: supportedKinds).prefix(MeasureRecentEntryKinds.maximum))
    }

    /// The last reading of each recent kind, for the rows' value column.
    var recentLastReadings: [MetricKind: Measurement] {
        var readings: [MetricKind: Measurement] = [:]
        for recent in recentKinds {
            readings[recent] = MeasureLastValue.reading(of: recent, in: store.recent)
        }
        return readings
    }

    /// The person's last reading of the form's kind and whether the typed
    /// value is far from it, under the value field.
    @ViewBuilder
    var lastValueLine: some View {
        if let last = MeasureLastValue.reading(of: kind, in: store.recent) {
            MeasureLastValueLine(reading: last, deviates: typedValueDeviates(from: last))
        }
    }

    /// Compared in the canonical unit, as the web does.
    private func typedValueDeviates(from last: Measurement) -> Bool {
        if kind == .bloodPressure {
            return MeasureLastValueDeviation.deviates(
                systolic: LocaleDecimalParser.parse(systolic).map { units.canonicalBloodPressure(fromDisplayed: $0) },
                diastolic: LocaleDecimalParser.parse(diastolic).map { units.canonicalBloodPressure(fromDisplayed: $0) },
                last: last
            )
        }
        let typed = LocaleDecimalParser.parse(scalar).map {
            MeasureEntryConversion.canonicalScalar($0, kind: kind, units: units)
        }
        return MeasureLastValueDeviation.deviates(kind: kind, canonical: typed, last: last)
    }

    /// The context the reading is filed with: the person's pick, else the
    /// default for the reading's time.
    var glucoseContext: GlucoseContext {
        pickedGlucoseContext ?? GlucoseContextDefault.context(at: recordedAt, history: store.recent)
    }

    /// The picker shows the default until the person picks; a pick holds.
    var glucoseContextSelection: Binding<GlucoseContext> {
        Binding(get: { glucoseContext }, set: { pickedGlucoseContext = $0 })
    }

    /// The kind "Save and next" moves on to, `nil` to stay on this one.
    private var nextKind: MetricKind? {
        MeasureRecentEntryKinds.next(after: kind, recent: recentKinds)
    }

    /// "Speichern und weiter": saves, keeps the sheet open with the fields
    /// cleared and moves to the next kind the person usually logs, as the
    /// web's add form does.
    var saveAndNextSection: some View {
        Section {
            HLSettingsActionRow(
                icon: "plus",
                title: "measure.saveAndNext",
                subtitle: nextKind.map { next -> LocalizedStringKey in "measure.saveAndNext.then \(next.displayName)" },
                presents: .confirm
            ) {
                Task { _ = await save(goOn: true) }
            }
            .disabled(!canSave || saveGate.isSaving)
            .accessibilityIdentifier("measure-sheet.save-and-next")
        }
        .hlFormRowSurface()
    }

    /// The receipt of a "Save and next": value and Undo, in the sheet the
    /// person keeps typing in (the shell's slot sits under the sheet).
    @ViewBuilder
    var receiptInSheet: some View {
        if showsReceiptInSheet, let receipt = store.undoCoordinator?.current {
            HLUndoToast(
                message: receipt.message,
                ttlSeconds: Int(receipt.ttl.rounded()),
                onUndo: { Task { await store.undoCoordinator?.performUndo() } },
                onDismiss: { store.undoCoordinator?.dismiss(reason: .userDismissed) }
            )
            .padding(.horizontal, HLLayout.pageMargin)
            .padding(.bottom, HLSpace.md)
            .accessibilityIdentifier("measure-sheet.receipt")
        }
    }

    /// Saves the reading. `goOn` is "Save and next": the sheet stays open,
    /// the fields clear and the form moves to the next usual kind; otherwise
    /// the check draws and the scaffold closes the sheet on `true`.
    func save(goOn: Bool = false) async -> Bool {
        guard let value = enteredValue else { return false }
        // Propagate the glucose-context intent only when actually
        // entering a glucose measurement. Store guards this too, but the
        // explicit check here keeps the UI's "kind→fields" contract obvious.
        let contextForCapture: GlucoseContext? = kind == .glucose ? glucoseContext : nil
        let savedKind = kind
        var captureError: HLError?
        var saved: Measurement?
        let ok = await saveGate.submit {
            saved = await store.captureReturningSaved(
                kind: savedKind,
                value: value,
                note: note.isEmpty ? nil : note,
                glucoseContext: contextForCapture,
                // Item 1.4b — the operator-chosen instant, not an implicit `.now`.
                recordedAt: recordedAt
            )
            if saved != nil { return nil }
            captureError = store.error
            return captureError ?? .unknown(String(localized: "Save failed. Please try again."))
        }
        // A tap while the first save is still running does nothing.
        if !ok, saveGate.error == nil { return false }
        guard ok, let saved else {
            saveErr &+= 1
            // Surface the store's error in the banner. Fall back to a
            // generic `.unknown` if the store didn't record one.
            saveError = captureError ?? .unknown(
                String(localized: "Save failed. Please try again.")
            )
            return false
        }
        // Remember this kind as last-used + push it to the front of the
        // recent-kinds MRU so the next open defaults here.
        persistRecentKind(savedKind)
        ReviewPromptCoordinator.live.noteMeasurement(
            kind: savedKind, value: value, glucoseContext: contextForCapture, outcome: .success
        )
        saveOk &+= 1
        // #191 QoL — the receipt: what was saved, with Undo.
        // Undo removes the row through the list's own delete, which offers
        // its own Undo in turn.
        store.undoCoordinator?.enqueue(
            message: MeasureEntryWording.receipt(kind: savedKind, value: value, units: units)
        ) { [store] in
            _ = await store.delete(saved)
        }
        if goOn {
            showsReceiptInSheet = true
            clearForNext()
            return true
        }
        // Let the check draw before the sheet goes; without motion it
        // stands drawn and the pause is shorter.
        isSaved = true
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 600))
        return true
    }

    /// The typed reading in canonical units, or `nil` when nothing usable is
    /// typed. Blood pressure and the scalar fields inverse-convert from the
    /// account's unit (identity for canonical prefs); pain is the clamped
    /// 0 to 10 integer.
    private var enteredValue: MeasurementValue? {
        if kind == .bloodPressure {
            guard let s = LocaleDecimalParser.parse(systolic), let d = LocaleDecimalParser.parse(diastolic) else { return nil }
            return .bloodPressure(
                systolic: units.canonicalBloodPressure(fromDisplayed: s),
                diastolic: units.canonicalBloodPressure(fromDisplayed: d)
            )
        }
        if kind == .painNRS {
            return .scalar(Double(PainScoreInput.clamp(painScore)))
        }
        return LocaleDecimalParser.parse(scalar).map {
            MeasurementValue.scalar(MeasureEntryConversion.canonicalScalar($0, kind: kind, units: units))
        }
    }

    /// After "Save and next": the reading's fields clear, the time stays (one
    /// sitting, one moment), the context goes back to its default, and the
    /// form moves to the next usual kind with the keyboard on its field.
    private func clearForNext() {
        let next = nextKind
        systolic = ""
        diastolic = ""
        scalar = ""
        painScore = 0
        note = ""
        pickedGlucoseContext = nil
        if let next { kind = next }
        primaryFocused = true
    }
}
