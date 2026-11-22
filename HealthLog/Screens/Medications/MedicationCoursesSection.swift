import Observation
import SwiftUI

/// **The treatment courses of a medication,
/// under "Erweitert" on its page.**
///
/// A centred text link "Erweitert" (the pattern of the Coach and the report
/// language) folds out the card "Behandlungen": every course from
/// `GET /api/medications/{id}/courses`, newest first, with its first and last
/// day and, for a course ended with "End treatment", the moment it ended. A
/// past course opens ``MedicationCourseEditPage`` to correct its days or to
/// delete it; "Neue Behandlung starten" appears only where the server says
/// `canStartCourse`. Ending stays the edit sheet's "Behandlung beenden" (MED).
///
/// Shown only with a server whose rows carry the course summary
/// (v1.40, `courseCount`); an older server sees the page as before. The list is read when the person opens it, not on every
/// visit. A refusal (the module off, or a delegate: the read is owner-only)
/// shows ``FeatureDisabledCard``; any other failure one sentence and "Retry".
struct MedicationCoursesSection: View {
    let medication: Medication

    @Environment(\.appContainer) private var container
    @Environment(MedicationsStore.self) private var medicationsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = MedicationCoursesModel()
    @State private var isExpanded = false

    var body: some View {
        if let container, medication.offersCourseHistory {
            VStack(spacing: HLSpace.sm) {
                advancedLink
                if isExpanded {
                    content
                        .task(id: medication.id) { await load(container) }
                        .transition(.opacity)
                }
            }
        }
    }

    private func load(_ container: AppContainer) async {
        let repo = container.medicationsRepo
        let id = medication.id
        let gate = container.moduleGate
        let store = medicationsStore
        await model.load(
            medicationID: id,
            repo: repo,
            offReason: { gate.offReason(.medications) },
            afterWrite: { await store.load(force: true) }
        )
    }

    private var advancedLink: some View {
        HLLinkButton("Advanced", isExpanded: isExpanded) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isExpanded.toggle() }
        }
        .accessibilityIdentifier("med.courses.advanced")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            // A real view, so the `.task` above runs (it never does on `EmptyView`).
            HLInlineProgress()
                .frame(maxWidth: .infinity, minHeight: HLHitTarget.minimum)
                .accessibilityLabel(Text("med.courses.loading"))
        case let .loaded(list):
            MedicationCoursesCard(list: list, medication: medication, model: model)
        case let .disabled(reason):
            FeatureDisabledCard(variant: .inline, reason: reason)
                .accessibilityIdentifier("med.courses.disabled")
        case .failed:
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLCardLabel("med.courses.title")
                    Text("med.courses.loadFailed")
                        .hlText(.factLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    HLButton(HLControlWord.retry.key, variant: .secondary) {
                        Task { await model.reload() }
                    }
                    .accessibilityIdentifier("med.courses.retry")
                }
            }
        }
    }
}

/// The card: the courses, newest first, and the start action.
struct MedicationCoursesCard: View {
    let list: MedicationCourseList
    let medication: Medication
    let model: MedicationCoursesModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HLCard("med.courses.title") {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                if list.courses.isEmpty {
                    HLEmptyNote("med.courses.none")
                } else {
                    ForEach(list.newestFirst) { course in
                        row(course)
                    }
                }
                if MedicationCoursesModel.offersStart(list: list, medication: medication) {
                    HLButton("med.lifecycle.start", variant: .secondary) {
                        Task { await model.start() }
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("med.courses.start")
                }
                if let message = model.writeError {
                    HLFormErrorText(message)
                        .font(.hlCaption)
                }
            }
        }
        // A containing element, so the rows keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("med.courses.section")
    }

    @ViewBuilder
    private func row(_ course: MedicationCourse) -> some View {
        if course.isCorrectable {
            // A course is an entry, not a menu: the whole row opens it and
            // carries no chevron (Z2+).
            MedicationCourseRowLabel(course: course, stacked: dynamicTypeSize.isAccessibilitySize, opens: true)
                .hlRowLink { MedicationCourseEditPage(course: course, model: model) }
                .accessibilityIdentifier("med.courses.row.\(course.id)")
        } else {
            MedicationCourseRowLabel(course: course, stacked: dynamicTypeSize.isAccessibilitySize, opens: false)
                .accessibilityIdentifier("med.courses.row.\(course.id)")
        }
    }
}

/// One course: its days, and under them where it stands.
struct MedicationCourseRowLabel: View {
    let course: MedicationCourse
    let stacked: Bool
    let opens: Bool

    var body: some View {
        HLRowLayout(
            title: Text(verbatim: MedicationCourseFormat.range(course)),
            subtitle: MedicationCourseFormat.status(course).map { Text(verbatim: $0) },
            indicator: .hidden
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: MedicationCourseFormat.accessibilityLabel(course)))
        .accessibilityAddTraits(opens ? .isButton : [])
    }
}

/// How a course reads in the list. Calendar days are printed in UTC, where
/// they are anchored; `endedAt` is an instant and printed in the device zone.
enum MedicationCourseFormat {
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }

    static func range(_ course: MedicationCourse) -> String {
        guard let start = course.startDay.map(day) else { return course.startsOn }
        guard let end = course.endDay.map(day) else {
            return String(localized: "med.courses.since \(start)")
        }
        return String(localized: "med.courses.range \(start) \(end)")
    }

    static func status(_ course: MedicationCourse) -> String? {
        if let endedAt = course.endedAt {
            let date = HLDateFormat.date(endedAt, style: .abbreviated)
            return String(localized: "med.courses.endedAt \(date) \(HLTimeFormat.time(endedAt))")
        }
        switch course.status {
        case .current: return String(localized: "med.courses.status.current")
        case .upcoming: return String(localized: "med.courses.status.upcoming")
        case .ended: return String(localized: "med.courses.status.ended")
        case nil: return nil
        }
    }

    /// One VoiceOver sentence per row: the days, then the status.
    static func accessibilityLabel(_ course: MedicationCourse) -> String {
        [range(course), status(course)].compactMap(\.self).joined(separator: ", ")
    }
}

/// The section's state and its writes. The section holds it in `@State`;
/// ``load(medicationID:repo:offReason:afterWrite:)`` starts when the list is
/// opened, a write calls ``reload()`` and re-reads the medications, whose
/// window (and so every reminder) the server moved with the course.
@MainActor
@Observable
final class MedicationCoursesModel {
    enum State: Equatable {
        case idle
        case loaded(MedicationCourseList)
        case disabled(String?)
        case failed
    }

    private(set) var state: State = .idle
    private(set) var isWorking = false
    /// The sentence under the card after a refused start.
    private(set) var writeError: String?

    @ObservationIgnored private var medicationID: String?
    @ObservationIgnored private var repo: MedicationsRepository?
    @ObservationIgnored private var offReason: (@MainActor () -> String?)?
    @ObservationIgnored private var afterWrite: (@MainActor () async -> Void)?

    func load(
        medicationID: String,
        repo: MedicationsRepository,
        offReason: @escaping @MainActor () -> String? = { nil },
        afterWrite: @escaping @MainActor () async -> Void = {}
    ) async {
        self.medicationID = medicationID
        self.repo = repo
        self.offReason = offReason
        self.afterWrite = afterWrite
        await reload()
    }

    func reload() async {
        guard let repo, let medicationID else { return }
        do {
            state = try await .loaded(repo.courses(medicationID: medicationID))
        } catch {
            state = Self.stateAfter(error, offReason: offReason?()) ?? state
        }
    }

    /// Starts a new open course today (the account's day). Offered only where
    /// ``offersStart(list:medication:)`` says so.
    func start(now: Date = .now) async {
        guard let repo, let medicationID, !isWorking else { return }
        isWorking = true
        writeError = nil
        defer { isWorking = false }
        do {
            try await repo.startCourse(medicationID: medicationID, startsOn: ProfileDay.key(for: now))
            await finishWrite()
        } catch {
            writeError = Self.message(for: error)
        }
    }

    /// Corrects a past course. Throws the server's refusal for the page to say.
    func update(_ course: MedicationCourse, startsOn: String, endsOn: String) async throws {
        guard let repo, let medicationID else { return }
        try await repo.updateCourse(medicationID: medicationID, courseID: course.id, startsOn: startsOn, endsOn: endsOn)
        await finishWrite()
    }

    /// Deletes a course. One already gone counts as deleted.
    func delete(_ course: MedicationCourse) async throws {
        guard let repo, let medicationID else { return }
        do {
            try await repo.deleteCourse(medicationID: medicationID, courseID: course.id)
        } catch where Self.isGone(error) {
            // Nothing left to delete: the list is what needs to change.
        }
        await finishWrite()
    }

    private func finishWrite() async {
        await afterWrite?()
        await reload()
    }

    /// Start only where the server offers it, on an active medication.
    nonisolated static func offersStart(list: MedicationCourseList, medication: Medication) -> Bool {
        list.canStartCourse && medication.active
    }

    /// `nil` keeps the current state (a cancelled read changes nothing).
    nonisolated static func stateAfter(_ error: Error, offReason: String?) -> State? {
        if error is CancellationError { return nil }
        switch error as? HLError {
        case .canceled: return nil
        case .moduleDisabled: return .disabled(offReason)
        case let .server(status, _, _) where status == 403: return .disabled(offReason)
        default: return .failed
        }
    }

    nonisolated static func isGone(_ error: Error) -> Bool {
        if case let HLError.server(status, _, _) = error { return status == 404 }
        return false
    }

    /// What a refused course write says, by the server's code. `nil` for a
    /// cancelled one.
    nonisolated static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if case .canceled? = error as? HLError { return nil }
        switch MedicationsRepository.courseErrorCode(error) {
        case "medications.course.overlap": return String(localized: "med.courses.error.overlap")
        case "medications.course.invalidRange": return String(localized: "med.schedule.course.invalidRange")
        case "medications.course.currentOpen": return String(localized: "med.courses.error.currentOpen")
        case "medications.course.notFound": return String(localized: "med.courses.error.gone")
        default: break
        }
        switch error as? HLError {
        case .moduleDisabled: return String(localized: "med.courses.error.notAllowed")
        case let .server(status, _, _) where status == 403: return String(localized: "med.courses.error.notAllowed")
        case let .server(status, _, _) where status == 404: return String(localized: "med.courses.error.gone")
        default: return String(localized: "med.courses.error.generic")
        }
    }
}
