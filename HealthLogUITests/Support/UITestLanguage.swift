import Foundation

/// **1.5 L10N-CORE — the interface language a UI test launches the app in.**
///
/// One place for the launch arguments that force a language, instead of a
/// `language == "de" ? "de_DE" : "en_US"` branch in every rig. `-AppleLanguages`
/// picks the bundle localization the app renders (what `AppLanguage.current`
/// reads); `-AppleLocale` sets the region and formats to match, so a capture
/// never mixes German copy with US dates.
///
/// `.pseudoDouble` is the English interface with every catalogue string
/// doubled (`-NSDoubleLocalizedStrings YES`), the cheap way to see where a
/// longer language truncates or wraps before its translation exists.
enum UITestLanguage: String, CaseIterable {
    case de
    case en
    case nl
    case pseudoDouble

    /// Reads a rig's environment value (`HL_SWEEP_LANG`, `HL_MARKETING_LANG`):
    /// `de`, `en`, `nl`, or `pseudo`. Anything else, or nothing, is English.
    init(environmentValue: String?) {
        switch environmentValue?.lowercased() {
        case "de": self = .de
        case "nl": self = .nl
        case "pseudo", "pseudodouble": self = .pseudoDouble
        default: self = .en
        }
    }

    /// The bundle localization the app should resolve to.
    var bundleLanguage: String {
        switch self {
        case .de: "de"
        case .en, .pseudoDouble: "en"
        case .nl: "nl"
        }
    }

    /// The `-AppleLocale` value: the language's home region.
    var appleLocale: String {
        switch self {
        case .de: "de_DE"
        case .en, .pseudoDouble: "en_US"
        case .nl: "nl_NL"
        }
    }

    /// Short tag for file and folder names (`de`, `en`, `nl`, `pseudo`).
    var tag: String {
        switch self {
        case .pseudoDouble: "pseudo"
        default: rawValue
        }
    }

    /// The arguments to append to `XCUIApplication.launchArguments`.
    var launchArguments: [String] {
        var arguments = [
            "-AppleLanguages", "(\(bundleLanguage))",
            "-AppleLocale", appleLocale
        ]
        if self == .pseudoDouble {
            arguments += ["-NSDoubleLocalizedStrings", "YES"]
        }
        return arguments
    }
}
