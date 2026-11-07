import SwiftUI

public extension View {
    /// POLISH-C (C3) — a secure field that is not a sign-in: an access
    /// header value, an API key, a channel token, an export passphrase.
    ///
    /// iOS treats every filled secure field that leaves the window as a
    /// submitted login form and offers to save a password. That system
    /// prompt then swallows the next tap (the first Back after leaving the
    /// app did nothing, SET-ROUTE probe G). The one-time-code content type
    /// takes the field out of password saving and AutoFill; no capitals and
    /// no autocorrection, as for any secret. Sign-in and password screens
    /// keep their `.password` / `.newPassword` types.
    func hlSecretEntry() -> some View {
        textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}
