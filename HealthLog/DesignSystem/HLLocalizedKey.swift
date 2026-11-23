import SwiftUI

/// The words behind a catalog key, for the few building blocks that lay
/// words out one by one (``HLWholeWordText``) and so need them as a string.
///
/// A `LocalizedStringKey` keeps its key out of the public interface. Its
/// stored key is read by reflection; a key with arguments ("\(count) items")
/// gives `nil`, and the caller keeps drawing the `Text` it has, so the worst
/// case is the form from before.
enum HLLocalizedKey {
    /// The localized words of a plain key, or `nil` when the key carries
    /// arguments or cannot be read.
    static func string(_ key: LocalizedStringKey, bundle: Bundle = .main) -> String? {
        let fields = Mirror(reflecting: key).children
        guard let raw = fields.first(where: { $0.label == "key" })?.value as? String else { return nil }
        if let formatted = fields.first(where: { $0.label == "hasFormatting" })?.value as? Bool, formatted {
            return nil
        }
        if let arguments = fields.first(where: { $0.label == "arguments" })?.value as? [Any], !arguments.isEmpty {
            return nil
        }
        return string(forKey: raw, bundle: bundle)
    }

    /// The localized words of a key written as a string.
    static func string(forKey key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
