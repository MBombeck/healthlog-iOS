import SwiftUI

/// Log a day for an illness episode (v1.18.1 §B). Pre-fills via
/// `GET …/day-logs?date=` and upserts on `(episodeId, date)`. Captures
/// functional impact (0–3), fever (°C), graded symptoms (1–3 severity), and a
/// note.
struct LogDaySheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: IllnessStore
    let episodeId: String
    var onSaved: (() -> Void)?

    @State private var date = Date.now
    /// Parity 1.7 — **nullable**, defaulting to "not specified". A hard default
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
    @State private var isSaving = false
    @State private var isLoading = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("illness.daylog.section.date") {
                    DatePicker("illness.daylog.date", selection: $date, displayedComponents: [.date])
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
            .navigationTitle(Text("illness.daylog.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("illness.action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("illness.action.save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .task { await prefill() }
        }
    }

    private var impactSection: some View {
        Section("illness.daylog.section.impact") {
            Picker("illness.daylog.impact", selection: $functionalImpact) {
                // The blank option is what makes "not specified" reachable —
                // without it the Picker could never return to `nil` and the
                // nullable state would be cosmetic.
                Text("illness.daylog.impact.none").tag(Int?.none)
                ForEach(0 ... 3, id: \.self) { level in
                    Text(impactLabel(level)).tag(Int?.some(level))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var feverSection: some View {
        Section("illness.daylog.section.fever") {
            Toggle("illness.daylog.hasFever", isOn: $hasFever)
            if hasFever {
                HStack {
                    TextField("illness.daylog.feverC", text: $feverText)
                        .keyboardType(.decimalPad)
                    Text(verbatim: "°C").foregroundStyle(HLText.secondary)
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
                Label(LocalizedStringKey(entry.labelKey), systemImage: entry.icon)
            }
            if isSelected {
                Picker("illness.daylog.severity", selection: Binding(
                    get: { symptomSeverity[entry.key] ?? 1 },
                    set: { symptomSeverity[entry.key] = $0 }
                )) {
                    ForEach(1 ... 3, id: \.self) { level in
                        Text(severityLabel(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func prefill() async {
        isLoading = true
        defer { isLoading = false }
        // `try?` flattens the throwing-optional return to a single optional.
        guard let log = try? await store.dayLog(episodeId: episodeId, date: dayKey()) else {
            // Parity 1.7 — a day with NOTHING logged must reset the form. The
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
            feverText = fever.formatted(.number.precision(.fractionLength(0 ... 1)))
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

    /// Blank the capture fields (used when the selected day has no stored log).
    /// `date` is deliberately untouched — it is the selector, not a field.
    private func resetForm() {
        functionalImpact = nil
        hasFever = false
        feverText = ""
        symptomSeverity = [:]
        note = ""
    }

    private func save() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let trimmedNote = note.trimmingCharacters(in: .whitespaces)
        let symptoms = symptomSeverity
            .sorted { $0.key < $1.key }
            .map { IllnessSymptom(key: $0.key, severity: $0.value) }
        let fever: Double? = hasFever
            ? LocaleDecimalParser.parse(feverText)
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
            dismiss()
        } else {
            saveError = store.lastError ?? String(localized: "illness.save.failed")
        }
    }

    private func dayKey() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func impactLabel(_ level: Int) -> String {
        IllnessPresentation.impactLabel(for: level) ?? String(level)
    }

    private func severityLabel(_ level: Int) -> String {
        let template = String(localized: "illness.daylog.severity.option")
        return String(format: template, level)
    }
}
