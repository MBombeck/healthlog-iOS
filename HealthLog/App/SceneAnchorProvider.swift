import SwiftUI
#if canImport(UIKit) && canImport(AuthenticationServices)
    import AuthenticationServices
    import UIKit

    /// Provides the current key window as `ASPresentationAnchor` for Passkey requests.
    /// Klasse ist nicht-isoliert (init darf von überall aufgerufen werden), aber `anchor()`
    /// erfordert MainActor — wie vom Protokoll vorgeschrieben.
    final class SceneAnchorProvider: ASPresentationAnchorProvider, @unchecked Sendable {
        nonisolated static let shared = SceneAnchorProvider()

        nonisolated init() {}

        /// v0.10.0 (W-Onboarding, Issue 3b) — robuste Anchor-Resolution. Die
        /// frueheres Version gab bei fehlendem `foregroundActive`-Scene einen
        /// FRISCHEN, fensterlosen `ASPresentationAnchor()` zurueck — das
        /// System-Sheet hatte dann nichts zum Praesentieren und konnte stumm
        /// no-oppen, ohne je einen Delegate-Callback zu feuern → Spinner haengt
        /// fuer immer. Jetzt suchen wir den besten verfuegbaren Window:
        /// 1. keyWindow einer `foregroundActive`-Scene,
        /// 2. keyWindow / erstes Window irgendeiner verbundenen `UIWindowScene`,
        /// 3. nur wenn wirklich GAR kein Window existiert: `nil` — der Caller
        ///    (PasskeyService) wirft dann einen Fehler statt einen fensterlosen
        ///    Anchor weiterzureichen.
        @MainActor
        func resolveWindow() -> UIWindow? {
            let windowScenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            if let active = windowScenes.first(where: { $0.activationState == .foregroundActive }) {
                if let key = active.keyWindow { return key }
                if let first = active.windows.first { return first }
            }
            for scene in windowScenes {
                if let key = scene.keyWindow { return key }
                if let first = scene.windows.first { return first }
            }
            return nil
        }

        @MainActor
        func anchor() -> ASPresentationAnchor {
            if let window = resolveWindow() { return window }
            // Letzte Verteidigungslinie — sollte mit aktiver UI nie passieren.
            // PasskeyService prueft auf einen fensterlosen Anchor und wirft,
            // bevor das System-Sheet ins Leere praesentieren wuerde.
            HLLog.auth.error("Passkey: kein praesentierbares Window gefunden — fensterloser Anchor.")
            return ASPresentationAnchor()
        }
    }
#endif
