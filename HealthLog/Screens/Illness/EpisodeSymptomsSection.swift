import SwiftUI

/// "Erfasste Symptome" on an
/// illness episode: the symptom occurrences the server files against this
/// episode, and only those, as on the web.
///
/// An occurrence belongs to the episode through its link (`episodeId`), never
/// through the episode's time span: two overlapping episodes each show their
/// own symptoms. A row opens ``SymptomEventSheet`` (time, intensity, note, the
/// episode link, delete). Under the card, while the episode runs, a centred
/// text link "Symptom erfassen" opens the same page for a new occurrence.
///
/// Shown only with a server from v1.43.4 on (an older one ignores the
/// `episodeId` filter and would mix every symptom of the record in), and only
/// when there is something to show or, while the episode runs, something to
/// log. A refusal shows ``FeatureDisabledCard``; any other failure the heading
/// with one sentence and "Retry".
struct EpisodeSymptomsSection: View {
    let store: IllnessStore
    let episode: IllnessEpisodeDTO

    @Environment(\.appContainer) private var container
    /// Observed so the section appears as soon as the version probe lands.
    @AppStorage(KnownServerVersion.defaultsKey) private var serverVersion: String?
    /// The `/api/version` keys; `day.dose-offset` opens the offset line.
    @AppStorage(ServerFeatureKeys.defaultsKey) private var featureKeys: String?
    @State private var model = EpisodeSymptomsModel()

    /// The placement gate, pure so it is testable without a view host. An
    /// unknown version answers no (Regel 10).
    nonisolated static func isAvailable(serverVersion: String?) -> Bool {
        guard let serverVersion else { return false }
        return ServerVersionInfo(version: serverVersion).isAtLeast(SymptomEventsRepository.minimumServerVersion)
    }

    var body: some View {
        if let container, Self.isAvailable(serverVersion: serverVersion) {
            content
                .task(id: episode.id) {
                    let repo = SymptomEventsRepository(api: container.api)
                    let id = episode.id
                    let gate = container.moduleGate
                    await model.load(
                        events: { try await repo.events(episodeId: id) },
                        definitions: { try await repo.definitions() },
                        offReason: { gate.offReason(.illness) }
                    )
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            // A real (zero-height) view: a `.task` on `EmptyView` never runs,
            // and the read would never start.
            Color.clear
                .frame(height: 0)
                .accessibilityHidden(true)
        case let .loaded(rows):
            if EpisodeSymptomsModel.isVisible(rows: rows, episodeIsActive: episode.isActive, canLog: model.canLog) {
                VStack(spacing: HLSpace.sm) {
                    card(rows)
                    if episode.isActive, model.canLog {
                        addLink
                    }
                }
            }
        case let .disabled(reason):
            FeatureDisabledCard(variant: .inline, reason: reason)
                .accessibilityIdentifier("symptoms.disabled")
        case .failed:
            HLCard("symptoms.episode.title") {
                HLEmptyNote("symptoms.loadFailed")
                HLButton(HLControlWord.retry.key, variant: .secondary) {
                    Task { await model.reload() }
                }
                .accessibilityIdentifier("symptoms.retry")
            }
        }
    }

    private func card(_ rows: [EpisodeSymptomsModel.Row]) -> some View {
        HLCard("symptoms.episode.title", layout: rows.isEmpty ? .free : .rows) {
            if rows.isEmpty {
                HLEmptyNote("symptoms.episode.empty")
            } else {
                ForEach(rows) { row in
                    let offset = EpisodeSymptomsModel.doseOffset(of: row, featureKeys: featureKeys)
                    SymptomEventRow(row: row, doseOffset: offset)
                        .hlRowLink {
                            editor(.edit(row.event, label: row.label))
                        }
                        // On the link, so the identifier names the tap target.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(SymptomEventFormat.spokenLabel(row, doseOffset: offset)))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("symptoms.row.\(row.event.id)")
                }
            }
        }
        // A containing element, so the rows keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("symptoms.section")
    }

    /// The centred text link under the card, like "Erweitert" elsewhere.
    private var addLink: some View {
        HLLinkButton("symptoms.add", systemImage: "plus", destination: {
            editor(.create(model.activeDefinitions))
        })
        .accessibilityIdentifier("symptoms.add")
    }

    private func editor(_ mode: SymptomEventSheet.Mode) -> some View {
        SymptomEventSheet(
            mode: mode,
            episode: episode,
            episodes: store.episodes,
            repository: container.map { SymptomEventsRepository(api: $0.api) }
        ) {
            await model.reload()
        }
    }
}

/// One occurrence as a two-line row: the symptom, when, and its intensity
/// out of ten as the value. The row stacks itself at the accessibility sizes.
/// With a server that names the `day.dose-offset` key, one quiet line under it says where the
/// symptom sat against the day's dose ("2 Std. 10 Min. nach Metformin").
struct SymptomEventRow: View {
    let row: EpisodeSymptomsModel.Row
    var doseOffset: DayDoseOffset?

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.xxs) {
            HLRow(
                title: Text(verbatim: SymptomEventFormat.label(row.label)),
                detail: Text(verbatim: SymptomEventFormat.time(row.event)),
                value: Text("symptoms.intensity.pill \(row.event.intensity)")
            )
            if let doseOffset {
                Text(verbatim: DoseOffsetFormat.text(doseOffset))
                    .hlText(.rowStatus)
                    .accessibilityIdentifier("symptoms.row.doseOffset")
            }
        }
    }
}

/// Pure presentation helpers, kept apart so tests can pin them.
enum SymptomEventFormat {
    /// The symptom's label as the person wrote it; an unreadable one says so.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return String(localized: "symptoms.unreadableLabel") }
        return raw
    }

    /// Date and time in the user's date preference.
    static func time(_ event: SymptomEvent) -> String {
        IllnessDateFormat.mediumDateTime(event.occurredAt)
    }

    /// What VoiceOver reads: the symptom, its intensity out of ten, when, and
    /// where it sat against the day's dose when the server says so.
    static func spokenLabel(_ row: EpisodeSymptomsModel.Row, doseOffset: DayDoseOffset? = nil) -> String {
        let base = String(localized: "symptoms.row.a11y \(label(row.label)) \(row.event.intensity) \(time(row.event))")
        return HLRowDetail.joined([base, doseOffset.map { DoseOffsetFormat.text($0) }]) ?? base
    }
}

/// The section's state. The page holds it in `@State`; ``load(events:definitions:offReason:)``
/// starts from the section's `.task`, and an edit calls ``reload()``.
@MainActor
@Observable
final class EpisodeSymptomsModel {
    struct Row: Identifiable, Equatable {
        let event: SymptomEvent
        /// The definition's label, `nil` when unreadable or unknown.
        let label: String?

        var id: String {
            event.id
        }
    }

    enum State: Equatable {
        case idle
        case loaded([Row])
        case disabled(String?)
        case failed
    }

    private(set) var state: State = .idle
    /// The symptoms that can be logged (active ones, in the server's order).
    private(set) var activeDefinitions: [SymptomDefinition] = []

    var canLog: Bool {
        !activeDefinitions.isEmpty
    }

    @ObservationIgnored private var fetchEvents: (@MainActor () async throws -> [SymptomEvent])?
    @ObservationIgnored private var fetchDefinitions: (@MainActor () async throws -> [SymptomDefinition])?
    @ObservationIgnored private var offReason: (@MainActor () -> String?)?

    func load(
        events: @escaping @MainActor () async throws -> [SymptomEvent],
        definitions: @escaping @MainActor () async throws -> [SymptomDefinition],
        offReason: @escaping @MainActor () -> String? = { nil }
    ) async {
        fetchEvents = events
        fetchDefinitions = definitions
        self.offReason = offReason
        await reload()
    }

    func reload() async {
        guard let fetchEvents, let fetchDefinitions else { return }
        do {
            let events = try await fetchEvents()
            let definitions = try await fetchDefinitions()
            let byID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            activeDefinitions = definitions.filter(\.isActive)
            state = .loaded(events.map { Row(event: $0, label: byID[$0.definitionId]?.label) })
        } catch {
            state = Self.stateAfter(error, offReason: offReason?()) ?? state
        }
    }

    /// #191 — the row's distance to the day's dose, straight from the
    /// occurrence the list read (`doseOffset` on `GET /api/symptoms/events`).
    /// Only behind the `day.dose-offset` key of `/api/version`: a server
    /// without it shows no offset, and the app never keys a day to find one.
    nonisolated static func doseOffset(of row: Row, featureKeys: String?) -> DayDoseOffset? {
        guard ServerFeatureKeys.isOpen(.dayDoseOffset, in: featureKeys) else { return nil }
        return row.event.doseOffset
    }

    /// `nil` keeps the current state (a cancelled read changes nothing). A
    /// refusal (the module, or a grant that does not reach it) is the
    /// disabled card; everything else can be tried again.
    nonisolated static func stateAfter(_ error: Error, offReason: String?) -> State? {
        if error is CancellationError { return nil }
        switch error as? HLError {
        case .canceled: return nil
        case .moduleDisabled: return .disabled(offReason)
        case let .server(status, _, _) where status == 403: return .disabled(offReason)
        default: return .failed
        }
    }

    /// Something to show, or, while the episode runs, something to log.
    nonisolated static func isVisible(rows: [Row], episodeIsActive: Bool, canLog: Bool) -> Bool {
        !rows.isEmpty || (episodeIsActive && canLog)
    }
}
