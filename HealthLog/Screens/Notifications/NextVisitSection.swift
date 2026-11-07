import SwiftUI

/// **1.5 VISIT (#149 item 2)** — "Nächster Termin" at the top of Vorsorge,
/// only while a visit is booked.
///
/// The app has no visit list and gets none; appointments already lead here
/// (`/checkups`, `visit.view`). The section shows the booked visit's date and
/// practice, where its preparation window starts and why (`preparation`, as
/// the server resolved it), up to five rows of what stood out since
/// (`GET /api/day/notable` for that window) and a link to the doctor report
/// for exactly that window. Nothing is recomputed: every date is the server's,
/// every sentence a key from the app's bundle around the record's own names.
///
/// A server without `preparation` (before v1.43.11) gets date and practice
/// only. No visit, no section; a grant without visits shows the shared
/// disabled card; a failed read shows the heading with a retry.
///
/// It wraps the page's own content: the read hangs on that content, which is
/// always on screen, because a `.task` on a section that draws nothing until
/// it has an answer would never start.
struct NextVisitSection<PageContent: View>: View {
    @ViewBuilder let pageContent: () -> PageContent

    @Environment(BackendAvailability.self) private var backend
    @Environment(AppRouter.self) private var router
    @Environment(\.appContainer) private var appContainer
    @State private var model: NextVisitModel?
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.lg) {
            if backend.hasServer {
                content
            }
            pageContent()
        }
        .task(id: LoadKey(focus: router.focusedVisitId, attempt: attempt, hasServer: backend.hasServer)) {
            guard backend.hasServer, let model = resolvedModel() else { return }
            await model.load(focus: router.focusedVisitId)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.phase ?? .loading {
        case .loading, .hidden:
            EmptyView()
        case let .loaded(next):
            NextVisitCard(next: next)
        case let .disabled(reason):
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("visit.next.title")
                FeatureDisabledCard(variant: .inline, reason: reason)
            }
            .accessibilityIdentifier("visit.next.disabled")
        case .failed:
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLSectionLabel("visit.next.title")
                    Text("visit.next.loadFailed")
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HLButton("Retry", variant: .secondary, size: .compact) { attempt += 1 }
                        .accessibilityIdentifier("visit.next.retry")
                }
            }
            .accessibilityIdentifier("visit.next.failed")
        }
    }

    private func resolvedModel() -> NextVisitModel? {
        if let model { return model }
        guard let api = appContainer?.api else { return nil }
        let created = NextVisitModel(repository: EncountersRepository(api: api))
        model = created
        return created
    }

    private struct LoadKey: Equatable {
        let focus: String?
        let attempt: Int
        let hasServer: Bool
    }
}

/// The loaded section: one card.
struct NextVisitCard: View {
    let next: NextVisitModel.NextVisit

    var body: some View {
        let visit = next.visit
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSectionLabel("visit.next.title")
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: HLSpace.xxs) {
                    Text(verbatim: HLDateFormat.dateTime(visit.occurredAt))
                        .font(.hlHeadline)
                        .foregroundStyle(HLText.primary)
                    if let practice = NextVisitFormat.practiceLine(visit.practitioner) {
                        Text(verbatim: practice)
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("visit.next.when")
                if let preparation = visit.preparation {
                    Text(verbatim: NextVisitFormat.sinceLine(preparation))
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("visit.next.since")
                }
                if !next.notable.isEmpty {
                    notable(next.notable)
                }
                if let preparation = visit.preparation, let window = ReportWindow(preparation: preparation) {
                    reportLink(window)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("visit.next")
    }

    private func notable(_ rows: [NextVisitModel.NotableRow]) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text("visit.next.notable.title")
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                let date = NextVisitFormat.day(row.date)
                // Date above the sentence: a date column of varying width
                // left the sentences ragged.
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: date)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .monospacedDigit()
                    Text(verbatim: row.text)
                        .font(.hlSubhead)
                        .foregroundStyle(HLText.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(date), \(row.text)"))
            }
        }
        .padding(.top, HLSpace.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("visit.next.notable")
    }

    private func reportLink(_ window: ReportWindow) -> some View {
        NavigationLink {
            UnifiedSharingScreen(preselectedForm: .pdf, presetWindow: window)
        } label: {
            HStack(spacing: HLSpace.xs) {
                Image(systemName: "doc.text")
                    .font(.hlIcon(HLIconSize.sm))
                    .accessibilityHidden(true)
                Text("visit.next.report")
                    .font(.hlSubhead.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(HLText.secondary)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("visit.next.report")
    }
}

// MARK: - Wording (pure, testable)

enum NextVisitFormat {
    /// A day key in the user's date preference, read in the device calendar
    /// (the 3rd stays the 3rd in every zone); an unreadable key as sent.
    static func day(_ key: String, calendar: Calendar = .current) -> String {
        guard let parts = ReportWindow.dayComponents(key), let date = calendar.date(from: parts) else { return key }
        return HLDateFormat.date(date, style: .abbreviated)
    }

    /// "Praxis Dr. Weber, Dermatologie": the practice (else the name) and the
    /// specialty, as the address book holds them.
    static func practiceLine(_ practitioner: EncounterDTO.Practitioner?) -> String? {
        guard let practitioner else { return nil }
        let place = [practitioner.practice, practitioner.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let parts = [place, practitioner.specialty?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Where the window starts and why, as the server resolved it. A rule
    /// without the name it needs, or a rule this build does not know, falls
    /// back to the bare start date.
    static func sinceLine(_ preparation: EncounterPreparation, calendar: Calendar = .current) -> String {
        // POLISH-A A8 (server v1.47.1) — the window stopped at the two years a
        // report covers; it must not promise everything since that visit.
        if preparation.capped == true {
            return String(localized: "visit.next.since.capped")
        }
        let date = day(preparation.from, calendar: calendar)
        let since = preparation.since
        switch preparation.basis {
        case .practitioner:
            if let name = nonEmpty(since?.practitionerName) {
                return String(localized: "visit.next.since.practitioner \(name) \(date)")
            }
        case .specialty:
            if let specialty = nonEmpty(since?.specialty) {
                return String(localized: "visit.next.since.specialty \(specialty) \(date)")
            }
        case .kind:
            return String(localized: "visit.next.since.kind \(kindName(since?.kind)) \(date)")
        case .default:
            return String(localized: "visit.next.since.default")
        case .unknown:
            break
        }
        return String(localized: "visit.next.since.date \(date)")
    }

    /// The kinds the `kind` rule applies to; anything else reads as a visit.
    static func kindName(_ kind: String?) -> String {
        switch kind {
        case "ROUTINE": String(localized: "visit.kind.routine")
        case "PREVENTIVE": String(localized: "visit.kind.preventive")
        case "THERAPY": String(localized: "visit.kind.therapy")
        default: String(localized: "visit.kind.other")
        }
    }

    /// The sharing surface's line for a preset window: "12. Aug. 2026 bis
    /// 18. Nov. 2026".
    static func windowLine(_ window: ReportWindow, calendar: Calendar = .current) -> String {
        String(localized: "sharing.unified.period.window \(day(window.from, calendar: calendar)) \(day(window.to, calendar: calendar))")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension NotableWording {
    /// The app's wording: the day view's sentences from the web, around the
    /// record's own names and the app's metric names.
    static let app = NotableWording(
        change: { change in
            let label = change.title
            switch change.kind {
            case "medicationStart", "courseStart": return String(localized: "visit.notable.started \(label)")
            case "medicationEnd", "courseEnd": return String(localized: "visit.notable.ended \(label)")
            case "pauseStart": return String(localized: "visit.notable.paused \(label)")
            case "pauseEnd": return String(localized: "visit.notable.resumed \(label)")
            case "illnessOnset": return String(localized: "visit.notable.illnessBegan \(label)")
            case "illnessResolved": return String(localized: "visit.notable.illnessResolved \(label)")
            default: return label
            }
        },
        observation: { observation in
            guard let type = observation.type,
                  let kind = ServerMeasurementType(rawValue: type)?.metricKind else { return nil }
            let metric = String(localized: kind.descriptor.title)
            switch observation.kind {
            case "extremeHigh":
                guard let since = monthYear(observation.since) else { return nil }
                return String(localized: "visit.notable.extremeHigh \(metric) \(since)")
            case "extremeLow":
                guard let since = monthYear(observation.since) else { return nil }
                return String(localized: "visit.notable.extremeLow \(metric) \(since)")
            case "gap":
                guard let days = observation.days else { return nil }
                return String(localized: "visit.notable.gap \(metric) \(days)")
            default:
                // `firstValue` says nothing about the stretch since the visit
                // (the web leaves it out too); an unknown kind has no sentence.
                return nil
            }
        }
    )

    /// "August 2026" for the `since` of an extreme, in the interface language.
    static func monthYear(_ key: String?, calendar: Calendar = .current) -> String? {
        guard let key, let parts = ReportWindow.dayComponents(key), let date = calendar.date(from: parts) else { return nil }
        return date.formatted(.dateTime.month(.wide).year().locale(AppLanguage.current.formattingLocale))
    }
}
