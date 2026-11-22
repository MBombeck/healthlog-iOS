#if canImport(SpeziAccessGuard)
    import SpeziAccessGuard
#endif
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
    import UIKit
#endif

/// One-time presentation of a freshly-minted share-link token. The raw `hls_…`
/// token is returned by the server **only once** on create — this sheet is the
/// single moment the user can copy or share it. After dismissal it is dropped
/// (`store.clearFreshToken()`); it is unrecoverable.
///
/// **The content moved, the promise did not.** Everything below the
/// navigation chrome is ``ShareLinkTokenPanel``, because the unified sharing
/// surface reveals the same token **in place** and two copies of a Class-D
/// surface would eventually say two different things. This file keeps the sheet
/// presentation and ``copySensitive(_:)``: a source-level security pin
/// (`A360SecurityAppStoreFixTests`) reads this file by name for the clipboard
/// guards, so the helper stays where the pin looks.
struct ShareLinkTokenSheet: View {
    let store: ShareLinkStore

    @Environment(\.appContainer) private var container

    var body: some View {
        // GH #8 Path 2 — the raw `hls_…` token URL is shown exactly once;
        // guard the reveal behind Face ID (SpeziAccessGuard). The sheet's
        // Done button + swipe-down stay reachable while locked, so the
        // guard never traps the user (no UX regression).
        HLSheetScaffold("Share link ready", action: .done()) {
            guardedContent
        }
    }

    @ViewBuilder private var guardedContent: some View {
        #if canImport(SpeziAccessGuard)
            AccessGuarded(.sensitiveScreens) {
                sheetContent
            }
        #else
            sheetContent
        #endif
    }

    private var sheetContent: some View {
        HLPage {
            ShareLinkTokenPanel(store: store, baseURL: container?.environment.baseURL)
        }
    }

    #if canImport(UIKit)
        /// S-2 (A360-3 security) — copy a credential (share-link token / URL /
        /// passphrase) to the pasteboard with both privacy guards:
        ///   * `.localOnly: true` → Universal Clipboard does NOT mirror it to the
        ///     user's other Macs/iPads (a doctor-access token + its 2FA passphrase
        ///     must not fan out across devices).
        ///   * `.expirationDate` 120 s → the item self-clears from the clipboard so
        ///     it doesn't linger indefinitely for a later paste / a second user on a
        ///     shared device.
        /// The 2-minute window is enough to paste into the doctor's message and
        /// short enough to bound the exposure.
        static func copySensitive(_ string: String) {
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: string]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(120)
                ]
            )
        }
    #endif
}
