import SwiftUI

/// #137 (server v1.43) — one calm line above the cycle calendar when the
/// server merged a later start into the one just logged ("Your start on
/// 17 Sep was merged into 14 Sep.") or gave a start back ("The start on
/// 17 Sep is back."). The calendar itself already shows the result; this line
/// only says why it changed. Monochrome, dismissible, spoken once by VoiceOver
/// when it appears.
struct CycleStartNoticeRow: View {
    let notice: CycleStartNotice
    let onDismiss: () -> Void

    var body: some View {
        let sentence = notice.sentence()
        // A plain line in the calendar card: no decorative info
        // glyph and no box inside the card, the shared close button.
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.sm) {
            Text(sentence)
                .hlText(.prose)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HLIconButton(systemImage: "xmark", label: "cycle.startNotice.dismiss", action: onDismiss)
                .accessibilityIdentifier("cycle.startNotice.dismiss")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cycle.startNotice")
        .onAppear {
            AccessibilityNotification.Announcement(sentence).post()
        }
    }
}
