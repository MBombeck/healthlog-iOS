import SwiftUI

/// **Server v1.39.4 (#1040) — the course badge on a medication card and the
/// detail header.**
///
/// Reads the server's `courseStatus` and nothing else: `ENDED` says "Ended",
/// `UPCOMING` says "Starts on <date>". A current course, a server older than
/// v1.39.4 and an unknown status show no badge. Whether Taken / Skip are
/// offered is `intakeActionable`'s job (``Medication/offersIntakeActions``);
/// this only says why they are missing.
enum MedicationCourseBadge: Equatable {
    case ended
    case startsOn(Date)

    static func resolve(_ medication: Medication) -> MedicationCourseBadge? {
        switch medication.courseStatus {
        case .ended: .ended
        case .upcoming: medication.startsOn.map { .startsOn($0) }
        case .current, .unknown, nil: nil
        }
    }

    /// `startsOn` is a calendar date carried as UTC midnight, so it is printed
    /// in UTC — any other zone west of UTC would name the day before.
    var title: String {
        switch self {
        case .ended:
            return String(localized: "medications.course.ended.badge")
        case let .startsOn(date):
            let day = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
            return String(localized: "medications.course.upcoming.badge \(day)")
        }
    }
}

struct MedicationCourseStatusBadge: View {
    let badge: MedicationCourseBadge

    var body: some View {
        HStack(spacing: HLSpace.xxs) {
            Image(systemName: badge == .ended ? "flag.checkered" : "calendar")
                .font(.hlCaption2)
                .foregroundStyle(HLText.tertiary)
            Text(badge.title)
                .font(.hlCaption2.weight(.semibold))
                .foregroundStyle(HLText.secondary)
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xxs)
        .background(HLSurface.tertiary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(badge.title))
        .accessibilityIdentifier("medications.course.badge")
    }
}
