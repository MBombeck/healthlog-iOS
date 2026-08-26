import Foundation

/// **v0.5.7 G.4** — privacy-first prompt composition for the AskCoach
/// surface (`CoachConversationStore` → `LocalLLMService.respond`).
///
/// G.3 passed the user's raw text verbatim into the on-device
/// `LanguageModelSession`. G.4 enriches that text with a sanitized
/// snapshot of the user's local health data — latest BP / Puls / Gewicht
/// / Körperfett, 7-day Schritte + Schlaf averages, active medication
/// names, and the recent mood average — so the model can ground its
/// answer in concrete numbers instead of asking the user for the same
/// values back.
///
/// **Privacy-first invariants (load-bearing):**
/// 1. The snapshot is composed **on-device, no network calls**.
///    `snapshot(from:)` reads ONLY from in-memory stores
///    (`MeasurementsStore.measurements`, `MoodStore.entries`,
///    `MedicationsStore.activeMedications`) that the SWR layer has
///    already populated. No `MeasurementsRepository` round-trip, no
///    `URLSession` request, no SwiftData open. The dedicated test
///    `PrivacyFirstPromptBuilderTests.snapshotMakesNoNetworkCalls`
///    pins this by intercepting `URLProtocol` and asserting zero
///    request attempts.
/// 2. The composed prompt is fed into Apple FoundationModels'
///    `LanguageModelSession`, which is on-device by construction
///    (`LocalLLMService.respond(prompt:)` doc-header — no network egress
///    in the model path).
/// 3. The composed string is **never persisted** — it's a transient
///    value rebuilt per turn. Chat persistence (G.5) stores only the
///    user's raw text + the assistant's response, not the composed
///    prompt.
/// 4. Names + dosages of medications appear in plain text inside the
///    prompt so the model can reference them. This is OK because the
///    prompt never leaves the device. If the privacy boundary changes
///    (e.g. a future server-backed Full-Coach), this composer MUST be
///    re-audited before any network egress.
///
/// **Why a separate file from `CoachConversationStore`?** Audit-by-eye:
/// the prompt composition is the ONLY PII surface the LLM sees, so
/// isolating it in one struct keeps the privacy review trivially
/// scopeable. Mirrors the `MiniCoachPrompt` / `MiniCoachDataBinder`
/// split (the only-PII-surface module pattern is already established in
/// this codebase — see `MiniCoachDataBinder.swift` doc-header).
///
/// **Why a struct with static methods (vs an actor or instance type)?**
/// Pure value transformation: same input → same output, no shared
/// mutable state, no actor isolation needed. The `snapshot(...)` entry
/// point is `@MainActor` because it reads `@MainActor`-isolated stores;
/// `compose(...)` is fully nonisolated because it operates on a
/// `Sendable` snapshot value.
@MainActor
public struct PrivacyFirstPromptBuilder {
    /// Read the in-memory snapshot from the SWR-hydrated stores hanging
    /// off `AppContainer`. No network calls — every accessor pulled here
    /// is a synchronous read of cached state.
    ///
    /// **Snapshot freshness guarantee:** the stores feed off SWR caches
    /// that the AskCoach hero (Insights tab) has typically warmed
    /// during the same session. If a store is empty (cold launch +
    /// user opened AskCoach before any other tab), the corresponding
    /// field collapses to `nil` and `compose(...)` skips that line.
    /// No async load is forced here — that would violate the "snapshot
    /// is purely local" contract for the network-isolation test.
    public static func snapshot(from container: AppContainer) -> HealthSnapshot {
        let measurements = container.measurementsStore.recent
        let moods = container.moodStore.entries
        let activeMeds = container.medicationsStore.activeMedications
        return makeSnapshot(measurements: measurements, moods: moods, activeMeds: activeMeds, now: .now)
    }

    /// Pure constructor — exposed so tests can supply hand-rolled
    /// fixtures without needing a full `AppContainer`. `snapshot(from:)`
    /// is a thin wrapper that pulls the live store arrays and delegates
    /// here.
    ///
    /// `nonisolated` so the network-isolation test can pin all-nil
    /// snapshot composition from any actor context.
    ///
    /// **Deterministic clock (v0.6.0.7 B2-M3):** `now` is required, no
    /// default. Removes the silent `.now` default that previously
    /// undermined the deterministic-clock pattern used elsewhere in the
    /// builder. Tests pin a fixture; production sites pass `.now`.
    public nonisolated static func makeSnapshot(
        measurements: [Measurement],
        moods: [MoodEntry],
        activeMeds: [Medication],
        now: Date
    ) -> HealthSnapshot {
        HealthSnapshot(
            latestBP: latestBloodPressure(in: measurements),
            latestPulse: latestPulse(in: measurements),
            latestWeight: latestWeight(in: measurements),
            latestBodyFat: latestBodyFat(in: measurements),
            last7dStepsAvg: stepsAverage(in: measurements, now: now),
            last7dSleepAvgHours: sleepAverage(in: measurements, now: now),
            activeMedications: activeMeds.map { name(of: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            recentMoodAvg: recentMoodAvg(in: moods, now: now)
        )
    }

    /// Compose the final user-prompt string. German output by design
    /// (AskCoach is German-primary per R5 felt-quality target). The
    /// caller (`CoachConversationStore`) feeds the returned string into
    /// `LocalLLMService.respond(prompt:)` verbatim.
    ///
    /// **Empty-snapshot path:** when every snapshot field is `nil`, the
    /// composed prompt skips the bullet-list entirely — the model
    /// still gets the system instructions, the user question, and the
    /// disclaimer, so the answer remains coherent even on a cold
    /// launch with no data loaded yet. The test
    /// `composeHandlesAllNilSnapshotGracefully` pins this contract.
    ///
    /// **Why German-only output here?** The AskCoach surface is German-
    /// only today (the welcome lockup + suggestion chips in
    /// `AskCoachSheet` are German). When the surface grows an English
    /// path, this composer adds a locale parameter; for G.4 the German
    /// template is the single source of truth.
    ///
    /// **Deterministic clock (v0.6.0.7 B2-M3):** `now` is threaded
    /// through every relative-date renderer so the composed prompt is a
    /// pure function of `(userText, snapshot, now)`. Callers that need
    /// reproducible output (tests, debug-snapshot tooling) pin `now` to
    /// a fixture date; production callers pass `.now`. Removing the
    /// `Date = .now` default here mirrors the same pattern in
    /// `makeSnapshot(...)` and prevents the previously-silent
    /// `relativeDay()` default from undermining determinism.
    public nonisolated static func compose(
        userText: String,
        snapshot: HealthSnapshot,
        now: Date
    ) -> String {
        var lines: [String] = []

        lines.append(systemPreamble)
        lines.append("") // blank line

        let contextBullets = bullets(from: snapshot, now: now)
        if !contextBullets.isEmpty {
            lines.append("Kontext über letzte Vitalwerte:")
            lines.append(contentsOf: contextBullets)
            lines.append("") // blank line
        }

        lines.append("Frage des Nutzers:")
        // Fenced user-input block (v0.6.0.7 B3-M3). The previous
        // `"\(userText)"` interpolation let a user-supplied " or
        // newline break the surrounding prompt structure. On-device-
        // only AI means attacker == user, but defensive fencing is
        // cheap insurance and stops a stray quote in a real question
        // (e.g. "Was bedeutet \"Hypertonie\"?") from confusing the
        // model. `sanitiseForFence(...)` neutralises any embedded
        // `</user-input>` literal a user types inside their own
        // message so the closing fence cannot be terminated early.
        lines.append(userInputOpenFence)
        lines.append(sanitiseForFence(userText.trimmingCharacters(in: .whitespacesAndNewlines)))
        lines.append(userInputCloseFence)
        lines.append("") // blank line

        lines.append(taskInstruction)
        lines.append("") // blank line
        lines.append(disclaimer)

        return lines.joined(separator: "\n")
    }

    // MARK: - Composition strings

    /// `nonisolated` so `compose(...)` (also nonisolated) can read them
    /// without an actor hop. The values are immutable string literals,
    /// safe to expose process-wide.
    private nonisolated static let systemPreamble =
        "Du bist HealthLog Coach — sprich Deutsch, sei freundlich + sachlich + medizinisch verantwortungsvoll."

    private nonisolated static let taskInstruction =
        "Antworte als CoachInsight mit kurzer Headline, 2-3 Sätzen Befund-Einordnung, und 1-3 konkreten Handlungsvorschlägen."

    private nonisolated static let disclaimer =
        "Du gibst KEINE Diagnose. Bei Symptomen oder Sorgen empfehle den Arzt."

    /// Sentinel fences for the user-input block (v0.6.0.7 B3-M3).
    /// The opening + closing tokens each occupy their own line so the
    /// fence parser sees them as standalone markers. `sanitiseForFence`
    /// also neutralises any embedded close-fence the user types so
    /// the structure can't be terminated early.
    private nonisolated static let userInputOpenFence = "<user-input>"
    private nonisolated static let userInputCloseFence = "</user-input>"

    /// Defensive escape pass for raw user text rendered inside the
    /// `<user-input>` block. Replaces any embedded close-fence with a
    /// zero-width-space-broken variant so a user who literally types
    /// `</user-input>` (worst-case adversarial input) can't terminate
    /// the surrounding block. The replacement still renders as
    /// `</user-input>` to a human reader, so the user-question
    /// semantics are preserved when the model echoes the question
    /// back; only the prompt-structure boundary is protected.
    ///
    /// Open-fence + angle brackets are NOT escaped — they'd produce
    /// false-positives on common content (e.g. a user asking about
    /// `<sport-id>1234</sport-id>` in their own data export). Only
    /// the EXACT close-fence string is replaced, which is the only
    /// token that can prematurely terminate the block.
    private nonisolated static func sanitiseForFence(_ input: String) -> String {
        // Insert a U+200B between `<` and `/user-input>` so the literal
        // close-fence becomes `<\u{200B}/user-input>` — visually
        // identical for non-screen-reader content and structurally
        // distinct from the real `userInputCloseFence`.
        input.replacingOccurrences(of: userInputCloseFence, with: "<\u{200B}/user-input>")
    }

    private nonisolated static func bullets(from snapshot: HealthSnapshot, now: Date) -> [String] {
        var out: [String] = []
        if let bp = snapshot.latestBP {
            out.append("• Blutdruck: \(bp.sys)/\(bp.dia) mmHg (\(relativeDay(bp.date, now: now)))")
        }
        if let pulse = snapshot.latestPulse {
            out.append("• Puls: \(pulse.bpm) bpm (\(relativeDay(pulse.date, now: now)))")
        }
        if let weight = snapshot.latestWeight {
            out.append("• Gewicht: \(formatDecimal(weight.kg)) kg (\(relativeDay(weight.date, now: now)))")
        }
        if let bodyFat = snapshot.latestBodyFat {
            out.append("• Körperfett: \(formatDecimal(bodyFat.percent)) % (\(relativeDay(bodyFat.date, now: now)))")
        }
        if let steps = snapshot.last7dStepsAvg {
            out.append("• Schritte (Ø letzte 7 Tage): \(steps)")
        }
        if let sleep = snapshot.last7dSleepAvgHours {
            out.append("• Schlaf (Ø letzte 7 Tage): \(formatDecimal(sleep)) h")
        }
        if !snapshot.activeMedications.isEmpty {
            out.append("• Aktive Medikamente: \(snapshot.activeMedications.joined(separator: ", "))")
        }
        if let mood = snapshot.recentMoodAvg {
            out.append("• Stimmung Ø: \(mood)/5")
        }
        return out
    }

    private nonisolated static func formatDecimal(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    /// Compact human-relative date hint ("heute", "gestern", "vor 3
    /// Tagen"). German + intentionally fuzzy so the model treats it as
    /// observational context, not a hard timestamp. Locale-pinned to
    /// the user's calendar because the prompt is German-only today
    /// (see `compose` doc-header).
    ///
    /// **Deterministic (v0.6.0.7 B2-M3):** `now` is required, no
    /// default. Threaded from `compose(now:)` → `bullets(now:)` → here
    /// so the same input always yields the same output. Tests can pin
    /// `now` to a fixture; production callers pass `.now`.
    private nonisolated static func relativeDay(_ date: Date, now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if days <= 0 { return "heute" }
        if days == 1 { return "gestern" }
        return "vor \(days) Tagen"
    }

    // MARK: - Snapshot field extractors (pure derivations)

    private nonisolated static func latestBloodPressure(in measurements: [Measurement]) -> HealthSnapshot.BPReading? {
        // #33 — skip malformed 0-systolic/0-diastolic rows via the shared
        // `isDisplayableLatest` guard so the snapshot's latest BP falls back to
        // the most recent VALID reading instead of "0/77".
        for measurement in measurements.sorted(by: { $0.recordedAt > $1.recordedAt })
            where measurement.kind == .bloodPressure && measurement.isDisplayableLatest
        {
            if case let .bloodPressure(sys, dia) = measurement.value {
                return HealthSnapshot.BPReading(
                    sys: Int(sys.rounded()),
                    dia: Int(dia.rounded()),
                    date: measurement.recordedAt
                )
            }
        }
        return nil
    }

    private nonisolated static func latestPulse(in measurements: [Measurement]) -> HealthSnapshot.PulseReading? {
        latestScalar(in: measurements, kind: .pulse).map {
            HealthSnapshot.PulseReading(bpm: Int($0.value.rounded()), date: $0.date)
        }
    }

    private nonisolated static func latestWeight(in measurements: [Measurement]) -> HealthSnapshot.WeightReading? {
        latestScalar(in: measurements, kind: .weight).map {
            HealthSnapshot.WeightReading(kg: $0.value, date: $0.date)
        }
    }

    private nonisolated static func latestBodyFat(in measurements: [Measurement]) -> HealthSnapshot.BodyFatReading? {
        latestScalar(in: measurements, kind: .bodyFat).map {
            HealthSnapshot.BodyFatReading(percent: $0.value, date: $0.date)
        }
    }

    private nonisolated static func latestScalar(
        in measurements: [Measurement],
        kind: MetricKind
    ) -> (value: Double, date: Date)? {
        for measurement in measurements.sorted(by: { $0.recordedAt > $1.recordedAt }) where measurement.kind == kind {
            if case let .scalar(value) = measurement.value {
                return (value, measurement.recordedAt)
            }
        }
        return nil
    }

    private nonisolated static func stepsAverage(in measurements: [Measurement], now: Date) -> Int? {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let window = measurements.filter { $0.kind == .steps && $0.recordedAt >= cutoff }
        let values: [Double] = window.compactMap { m in
            if case let .scalar(v) = m.value { v } else { nil }
        }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return Int(avg.rounded())
    }

    private nonisolated static func sleepAverage(in measurements: [Measurement], now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let window = measurements.filter { $0.kind == .sleep && $0.recordedAt >= cutoff }
        let values: [Double] = window.compactMap { m in
            if case let .scalar(v) = m.value { v } else { nil }
        }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        return (avg * 10).rounded() / 10
    }

    private nonisolated static func recentMoodAvg(in moods: [MoodEntry], now: Date) -> Int? {
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let scores = moods.filter { $0.recordedAt >= cutoff }.map(\.score)
        guard !scores.isEmpty else { return nil }
        let avg = Double(scores.reduce(0, +)) / Double(scores.count)
        return Int(avg.rounded())
    }

    /// Render `Name dose` for an active medication. Trims trailing whitespace
    /// when `dose` is empty so the prompt line stays clean.
    private nonisolated static func name(of medication: Medication) -> String {
        let trimmedDose = medication.dose.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDose.isEmpty { return medication.name }
        return "\(medication.name) \(trimmedDose)"
    }
}

// MARK: - Snapshot value type

/// Sanitised, on-device view of the data the AskCoach turn is allowed to
/// reference. Named structs (vs raw tuples) so Swift auto-synthesises
/// `Equatable` + `Sendable`; the composer accesses fields by name so
/// the struct shape is invisible at the bullet-rendering boundary.
///
/// **Sendable + value-type** so the snapshot can cross actor hops if a
/// future streaming `respond` path needs it on a background context.
public struct HealthSnapshot: Sendable, Equatable {
    public let latestBP: BPReading?
    public let latestPulse: PulseReading?
    public let latestWeight: WeightReading?
    public let latestBodyFat: BodyFatReading?
    public let last7dStepsAvg: Int?
    public let last7dSleepAvgHours: Double?
    public let activeMedications: [String]
    public let recentMoodAvg: Int?

    public init(
        latestBP: BPReading? = nil,
        latestPulse: PulseReading? = nil,
        latestWeight: WeightReading? = nil,
        latestBodyFat: BodyFatReading? = nil,
        last7dStepsAvg: Int? = nil,
        last7dSleepAvgHours: Double? = nil,
        activeMedications: [String] = [],
        recentMoodAvg: Int? = nil
    ) {
        self.latestBP = latestBP
        self.latestPulse = latestPulse
        self.latestWeight = latestWeight
        self.latestBodyFat = latestBodyFat
        self.last7dStepsAvg = last7dStepsAvg
        self.last7dSleepAvgHours = last7dSleepAvgHours
        self.activeMedications = activeMedications
        self.recentMoodAvg = recentMoodAvg
    }

    /// Empty snapshot — every field nil. Used by call-sites that want
    /// to skip context injection (e.g. tests asserting the all-nil
    /// `compose(...)` path).
    public static let empty = HealthSnapshot()
}

public extension HealthSnapshot {
    struct BPReading: Sendable, Equatable {
        public let sys: Int
        public let dia: Int
        public let date: Date
        public init(sys: Int, dia: Int, date: Date) {
            self.sys = sys
            self.dia = dia
            self.date = date
        }
    }

    struct PulseReading: Sendable, Equatable {
        public let bpm: Int
        public let date: Date
        public init(bpm: Int, date: Date) {
            self.bpm = bpm
            self.date = date
        }
    }

    struct WeightReading: Sendable, Equatable {
        public let kg: Double
        public let date: Date
        public init(kg: Double, date: Date) {
            self.kg = kg
            self.date = date
        }
    }

    struct BodyFatReading: Sendable, Equatable {
        public let percent: Double
        public let date: Date
        public init(percent: Double, date: Date) {
            self.percent = percent
            self.date = date
        }
    }
}
