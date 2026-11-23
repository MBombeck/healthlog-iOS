import SwiftUI

/// Log a day for an illness episode (v1.18.1 §B). Pre-fills via
/// `GET …/day-logs?date=` and upserts on `(episodeId, date)`. Captures
/// functional impact (0–3), fever (°C), graded symptoms (1–3 severity), and a
/// note.
struct LogDaySheet: View {
    /// The fever is typed and shown in the account's unit (°F on an
    /// imperial account) and saved as canonical `feverC`.
    @Environment(\.unitPreferences) private var units

    let store: IllnessStore
    let episodeId: String
    var onSaved: (() -> Void)?

    @State private var date = Date.now
    /// **Nullable**, defaulting to "not specified". A hard default
    /// of `0` made every untouched day-log assert "fully functional", which
    /// pollutes the server's `FUNCTIONAL_IMPACT` burden track (it drives
    /// `gapDriverType`). Web models it as `number | null` with the same blank
    /// default (`log-day-sheet.tsx:161`).
    @State private var functionalImpact: Int?
    @State private var hasFever = false
    @State private var feverText = ""
    /// Selected symptoms → severity (1–3). Absence = not present.
    @State private var symptomSeverity: [String: Int] = [:]
    @State private var note = ""
    @State private var isLoading = false
    @State private var saveError: String?
    /// The form as it opened, for the discard guard.
    @State private var baseline: [AnyHashable]?

    var body: some View {
        HLSheetScaffold("illness.daylog.title", action: .save { await save() }, isDirty: isDirty) {
            Form {
                Group {
                    // A section of one row has no title of its own: the
                    // row is the heading ("Datum" over "Datum" said it twice).
                    Section {
                        DatePicker(selection: $date, displayedComponents: [.date]) {
                            HLRowTitle("illness.daylog.date")
                        }
                        // Pick days in the zone `dayKey` cuts in.
                        .environment(\.timeZone, ProfileDay.timeZone)
                        .onChange(of: date) { _, _ in
                            Task { await prefill() }
                        }
                    }
                    impactSection
                    feverSection
                    symptomsSection
                    Section("illness.daylog.section.note") {
                        TextField("illness.daylog.note", text: $note, axis: .vertical)
                            .lineLimit(2 ... 5)
                    }
                    if let saveError {
                        Section { HLFormErrorText(saveError) }
                    }
                }
                .hlFormRowSurface()
            }
            .hlPageMargins()
            .task { await prefill() }
        }
    }

    /// Every field the person can change, in one comparable value.
    private var formFingerprint: [AnyHashable] {
        [functionalImpact, hasFever, feverText, symptomSeverity, note]
    }

    private var isDirty: Bool {
        guard let baseline else { return false }
        return baseline != formFingerprint
    }

    private var impactSection: some View {
        Section {
            Picker(selection: $functionalImpact) {
                // The blank option is what makes "not specified" reachable —
                // without it the Picker could never return to `nil` and the
                // nullable state would be cosmetic.
                Text("illness.daylog.impact.none").tag(Int?.none)
                ForEach(0 ... 3, id: \.self) { level in
                    Text(impactLabel(level)).tag(Int?.some(level))
                }
            } label: {
                HLRowTitle("illness.daylog.impact")
            }
            .pickerStyle(.menu)
        }
    }

    private var feverSection: some View {
        Section("illness.daylog.section.fever") {
            Toggle(isOn: $hasFever) {
                HLRowTitle("illness.daylog.hasFever")
            }
            if hasFever {
                HStack {
                    TextField("illness.daylog.feverC", text: $feverText)
                        .keyboardType(.decimalPad)
                    Text(verbatim: units.unitLabel(for: .bodyTemperature)).foregroundStyle(HLText.secondary)
                }
            }
        }
    }

    private var symptomsSection: some View {
        Section("illness.daylog.section.symptoms") {
            ForEach(IllnessSymptomCatalog.all) { entry in
                symptomRow(entry)
            }
        }
    }

    private func symptomRow(_ entry: IllnessSymptomCatalogEntry) -> some View {
        let isSelected = symptomSeverity[entry.key] != nil
        return VStack(alignment: .leading, spacing: HLSpace.xs) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { on in
                    symptomSeverity[entry.key] = on ? (symptomSeverity[entry.key] ?? 1) : nil
                }
            )) {
                Label {
                    HLRowTitle(LocalizedStringKey(entry.labelKey))
                } icon: {
                    Image(systemName: entry.icon)
                }
            }
            if isSelected {
                HLAdaptiveSegmentedPicker(
                    "illness.daylog.severity",
                    selection: Binding(
                        get: { symptomSeverity[entry.key] ?? 1 },
                        set: { symptomSeverity[entry.key] = $0 }
                    ),
                    labels: (1 ... 3).map { LocalizedStringKey(severityLabel($0)) }
                ) {
                    ForEach(1 ... 3, id: \.self) { level in
                        Text(severityLabel(level)).tag(level)
                    }
                }
            }
        }
    }

    private func prefill() async {
        isLoading = true
        defer {
            isLoading = false
            // Picking another day loads that day, so the baseline follows it.
            baseline = formFingerprint
        }
        // `try?` flattens the throwing-optional return to a single optional.
        guard let log = try? await store.dayLog(episodeId: episodeId, date: dayKey()) else {
            // A day with NOTHING logged must reset the form. The
            // early return used to leave the previously-loaded day's values in
            // place, and since the body is a full-value upsert that would write
            // one day's impact / fever / symptoms / note onto another day. Web
            // resets on `dto === null` (`log-day-sheet.tsx:169`).
            resetForm()
            return
        }
        functionalImpact = log.functionalImpact
        if let fever = log.feverC {
            hasFever = true
            feverText = HLValueFormat.number(units.displayValue(fever, kind: .bodyTemperature), fractionDigits: 0 ... 1)
        } else {
            hasFever = false
            feverText = ""
        }
        var sev: [String: Int] = [:]
        for symptom in log.symptoms {
            sev[symptom.key] = symptom.severity ?? 1
        }
        symptomSeverity = sev
        note = log.note ?? ""
    }

    /// A fever typed in the account's unit, as canonical °C (2 decimals on an
    /// imperial account; verbatim on a metric one).
    nonisolated static func canonicalFeverC(_ typed: Double, units: UnitPreferences) -> Double {
        let transform = units.transform(for: .bodyTemperature)
        guard transform.rescales else { return typed }
        return (transform.canonical(fromDisplayed: typed) * 100).rounded() / 100
    }

    /// Blank the capture fields (used when the selected day has no stored log).
    /// `date` is deliberately untouched — it is the selector, not a field.
    private func resetForm() {
        functionalImpact = nil
        hasFever = false
        feverText = ""
        symptomSeverity = [:]
        note = ""
    }

    /// `true` when the sheet may close.
    private func save() async -> Bool {
        saveError = nil
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let symptoms = symptomSeverity
            .sorted { $0.key < $1.key }
            .map { IllnessSymptom(key: $0.key, severity: $0.value) }
        // Typed in the account's unit; stored canonical °C at 2 decimals (the
        // server's own entry dialect), so 101.3 °F persists as 38.5 °C.
        let fever: Double? = hasFever
            ? LocaleDecimalParser.parse(feverText).map { Self.canonicalFeverC($0, units: units) }
            : nil
        let body = IllnessDayLogUpsert(
            date: dayKey(),
            functionalImpact: functionalImpact,
            feverC: fever,
            symptoms: symptoms,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            loggedAt: ISO8601DateFormatter().string(from: Date())
        )
        if await store.upsertDayLog(episodeId: episodeId, body) {
            onSaved?()
            return true
        }
        saveError = store.lastError ?? String(localized: "illness.save.failed")
        return false
    }

    private func dayKey() -> String {
        Self.dayKey(for: date)
    }

    /// The day `date` names in the ACCOUNT zone, the zone the
    /// server keys illness day logs in (`(episodeId, date)`). The date picker
    /// above runs in the same zone, so the key is the day the person picked;
    /// "today" is the account's today.
    nonisolated static func dayKey(for date: Date, timeZone: TimeZone = ProfileDay.timeZone) -> String {
        ProfileDay.key(for: date, timeZone: timeZone)
    }

    private func impactLabel(_ level: Int) -> String {
        IllnessPresentation.impactLabel(for: level) ?? String(level)
    }

    private func severityLabel(_ level: Int) -> String {
        let template = String(localized: "illness.daylog.severity.option")
        return String(format: template, level)
    }
}
