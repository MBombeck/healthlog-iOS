import Observation
import SwiftUI

/// The "Related" section at the end of a lab
/// result, document, illness episode or medication page.
///
/// The server resolves `related` (v1.43+) and lists only kinds whose module is
/// on and that the caller's sharing grant covers, so the module and grant path
/// lives there: what is not allowed never arrives. The section shows nothing
/// when the list is empty or absent (an older server), one row per record with
/// its label and date otherwise. A kind with a page in the app (lab result,
/// document, episode, medication) opens it in the same navigation stack; a
/// visit or a vaccination has none and is not a link.
struct RelatedRecordsSection: View {
    let links: [RelatedLink]

    var body: some View {
        if !links.isEmpty {
            HLCard("related.title", layout: .rows) {
                ForEach(links) { link in
                    RelatedRecordRow(link: link)
                }
            }
        }
    }
}

/// One related record: its kind's symbol, the label, the date as the detail
/// line. A record with a page opens it as a whole row, without a chevron;
/// navigation is a view push inside whatever stack hosts the page.
struct RelatedRecordRow: View {
    let link: RelatedLink

    var body: some View {
        if link.kind.opensInApp {
            label
                .hlRowLink { RelatedRecordDestination(link: link) }
                .accessibilityIdentifier("related.row.\(link.kind.rawValue)")
        } else {
            label
                .accessibilityIdentifier("related.row.\(link.kind.rawValue)")
        }
    }

    private var label: some View {
        HLRow(
            title: Text(verbatim: link.label),
            detail: RelatedRecordFormat.date(link.date).map { Text(verbatim: $0) }
        ) {
            HLRowGlyph(symbol: link.kind.icon)
        }
        .accessibilityLabel(Text(verbatim: RelatedRecordFormat.spokenLabel(link)))
    }
}

/// Pure presentation helpers, kept apart so tests can pin them.
enum RelatedRecordFormat {
    /// The row's date in the user's date preference. A day key is read in the
    /// device calendar (a visit on the 3rd stays on the 3rd in every time
    /// zone), an instant as the instant. `nil` without a date; an unreadable
    /// value is shown as sent rather than dropped.
    static func date(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let instant = ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.plain.date(from: raw) {
            return HLDateFormat.date(instant, style: .abbreviated)
        }
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let local = Calendar.current.date(from: DateComponents(year: year, month: month, day: day)) else { return raw }
        return HLDateFormat.date(local, style: .abbreviated)
    }

    /// What VoiceOver reads: the kind, the record's label, its date.
    static func spokenLabel(_ link: RelatedLink) -> String {
        [kindName(link.kind), link.label, date(link.date)]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func kindName(_ kind: RelatedLink.Kind) -> String {
        switch kind {
        case .labResult: String(localized: "related.kind.labResult")
        case .encounter: String(localized: "related.kind.encounter")
        case .document: String(localized: "related.kind.document")
        case .conditionEpisode: String(localized: "related.kind.conditionEpisode")
        case .medication: String(localized: "related.kind.medication")
        case .vaccination: String(localized: "related.kind.vaccination")
        }
    }
}

/// The related list for a page whose own read does not carry it
/// (an episode and a medication are opened from their list rows). The page
/// holds this in `@State`, starts ``load(_:)`` from its `.task`, and puts
/// ``RelatedRecordsLoadedSection`` at its end.
///
/// No list, no section: an older server, an empty list, offline (the page's
/// sync footer already says so) and a refusal (`403`, the module or the grant)
/// all show nothing. Any other failure shows the heading with one sentence and
/// "Retry", and a value the server did not send is never shown.
@MainActor
@Observable
final class RelatedRecordsModel {
    enum State: Equatable {
        case idle
        case loaded([RelatedLink])
        case failed
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var fetch: (@MainActor () async throws -> [RelatedLink]?)?

    func load(_ fetch: @escaping @MainActor () async throws -> [RelatedLink]?) async {
        self.fetch = fetch
        await reload()
    }

    func reload() async {
        guard let fetch else { return }
        do {
            let links = try await fetch() ?? []
            state = .loaded(links)
        } catch {
            state = Self.stateAfter(error) ?? state
        }
    }

    /// `nil` keeps the current state (a cancelled read changes nothing).
    nonisolated static func stateAfter(_ error: Error) -> State? {
        if error is CancellationError { return nil }
        switch error as? HLError {
        case .canceled: return nil
        case .offline, .unauthorized, .moduleDisabled: return .loaded([])
        case let .server(status, _, _) where status == 403 || status == 404: return .loaded([])
        default: return .failed
        }
    }
}

struct RelatedRecordsLoadedSection: View {
    let model: RelatedRecordsModel

    var body: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case let .loaded(links):
            RelatedRecordsSection(links: links)
        case .failed:
            HLCard("related.title") {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    HLEmptyNote("related.loadFailed")
                    HLButton(HLControlWord.retry.key, variant: .secondary) {
                        Task { await model.reload() }
                    }
                    .accessibilityIdentifier("related.retry")
                }
            }
        }
    }
}
