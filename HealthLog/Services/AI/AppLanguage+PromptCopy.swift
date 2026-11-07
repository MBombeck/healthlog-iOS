import Foundation

/// Per-language copy selection for the on-device prompt builders.
///
/// Every builder in `Services/AI` used to branch on
/// `locale.language.languageCode?.identifier ?? "de"` with a German
/// `default:`, so a Dutch reader (and every device language the app does not
/// ship) got German prompts and German model output. The builders now resolve
/// the locale through `AppLanguage.resolve(_: Locale)` (unknown languages
/// read English, like the interface) and pick their copy here. The switch is
/// exhaustive on purpose: a fourth interface language fails to compile at
/// every prompt instead of silently inheriting one of the others.
extension AppLanguage {
    /// The variant for this language.
    func pick<Value>(de: Value, en: Value, nl: Value) -> Value {
        switch self {
        case .de: de
        case .en: en
        case .nl: nl
        }
    }
}
