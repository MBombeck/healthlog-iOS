import Foundation

/// **B5 (1.4)** — the word typed to confirm deleting the account or all data.
///
/// The catalog shows it per language (`DELETE` key: „LÖSCHEN“ in German,
/// „DELETE“ in English). Up to 1.3 the German word was spelled „LOESCHEN“,
/// and people who learned it, or whose keyboard has no umlaut at hand, may
/// still type that. The comparison stays exact and case-sensitive, as before;
/// the only addition is that a phrase with an umlaut also accepts its spelling
/// with ae, oe, ue or ss.
enum DeleteConfirmationPhrase {
    /// Whether `typed` confirms `required`.
    static func matches(_ typed: String, required: String) -> Bool {
        typed == required || typed == transliterated(required)
    }

    /// `required` with its umlauts and ß spelled out, the way they are typed
    /// without them: LÖSCHEN becomes LOESCHEN. Upper case stays upper case.
    static func transliterated(_ phrase: String) -> String {
        // A transliteration table, not user copy.
        let spelled: [Character: String] = [
            "Ä": "AE", "Ö": "OE", "Ü": "UE", "ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss", "ẞ": "SS" // i18n-guard: allow
        ]
        return phrase.reduce(into: "") { result, character in
            result += spelled[character] ?? String(character)
        }
    }
}
