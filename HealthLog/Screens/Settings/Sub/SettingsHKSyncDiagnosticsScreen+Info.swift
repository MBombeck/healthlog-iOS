import SwiftUI

// 1.4 B2-c — "Was bedeutet das?" for Sync Diagnostics.
//
// The screen carried nine explanations under or above its cards (R2 1.3):
// a source line at the top of every card, the session note, a card that only
// held a glossary, a card that only held the background limits, the reading
// guide of the server view, the legend of its times, and the long footer of
// the day totals. They are one sheet now, behind the screen's one (i), in the
// order a person reads the page; the cards keep their titles, values and
// actions.

extension SettingsHKSyncDiagnosticsScreen {
    var info: HLInfoContent {
        HLInfoContent(
            title: String(localized: "settings.hkdiag.title"),
            identifier: "settings.hkdiag.info.sheet",
            about: String(localized: "settings.hkdiag.info.about"),
            sections: [
                section("settings.hkdiag.info.sources.title", [
                    "settings.hkdiag.info.sources.server",
                    "settings.hkdiag.info.sources.session",
                    "settings.hkdiag.info.sources.stored"
                ]),
                section("settings.hkdiag.explainer_title", [
                    "settings.hkdiag.explainer_read",
                    "settings.hkdiag.explainer_upload",
                    "settings.hkdiag.kinds_subtitle"
                ]),
                section("settings.hkdiag.server_title", [
                    "settings.hkdiag.server_footer",
                    "settings.hkdiag.freshness_legend"
                ]),
                section("settings.hkdiag.stats.title", [
                    "settings.hkdiag.stats.footer",
                    "settings.hkdiag.hrbuckets.subtitle"
                ]),
                section("settings.hkdiag.info.held.title", [
                    "settings.hkdiag.held_subtitle",
                    "settings.hkdiag.skipped_subtitle"
                ]),
                section("settings.hkdiag.limits_title", [
                    "settings.hkdiag.limits_forcequit",
                    "settings.hkdiag.limits_bgrefresh",
                    "settings.hkdiag.limits_discretion",
                    "settings.hkdiag.limits_footer"
                ])
            ]
        )
    }

    private func section(_ title: String, _ paragraphs: [String]) -> HLInfoContent.Section {
        HLInfoContent.Section(
            title: String(localized: String.LocalizationValue(title)),
            paragraphs: paragraphs.map { String(localized: String.LocalizationValue($0)) }
        )
    }
}
