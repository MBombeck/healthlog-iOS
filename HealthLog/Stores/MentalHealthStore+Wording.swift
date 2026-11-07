import Foundation

/// L10N-MH: which questionnaire text the form shows, and what the submit says
/// about it.
///
/// The text is the reader's interface language (``AppLanguage``) from the
/// bundled server wording. Where that text is HealthLog's own translation and
/// not a published validated one (server v1.46.6: the SCI in German and
/// Dutch), the form says so and offers the English original. The submit then
/// tells the server which text the answers were given in (`englishOriginal`),
/// but only a server known to read the field (1.46.0+); an older or unknown
/// server gets the 1.4 body.
extension MentalHealthStore {
    /// First server whose screener body takes `englishOriginal` and whose rows
    /// carry `wording` (#151).
    static let englishOriginalMinimumServerVersion = "1.46.0"

    /// The text the form shows for the running administration.
    public var activeWording: QuestionnaireWording? {
        activeInstrument.wording(in: activeWordingLanguage) ?? activeInstrument.wording(in: .en)
    }

    /// The language of ``activeWording``: English once the reader switched to
    /// the original, else the interface language.
    public var activeWordingLanguage: AppLanguage {
        showsEnglishOriginal && translationIsUnvalidated ? .en : language
    }

    /// The reader's own text for the running instrument is a translation
    /// without published validation, so the form shows the note and the
    /// switch to the English original.
    public var translationIsUnvalidated: Bool {
        activeInstrument.wording(in: language)?.validated == false
    }

    /// Switch between the reader's translation and the English original.
    /// No effect where the translation is validated.
    public func toggleEnglishOriginal() {
        guard translationIsUnvalidated else {
            showsEnglishOriginal = false
            return
        }
        showsEnglishOriginal.toggle()
    }

    /// The wording of the running administration, decided the way the server
    /// decides it (`presentedWording`, `wording/resolve.ts`).
    var presentedWording: AssessmentWording {
        presentedWording(for: activeInstrument)
    }

    func presentedWording(for instrument: MentalHealthInstrument) -> AssessmentWording {
        if language == .en { return .validated }
        if showsEnglishOriginal, instrument.wording(in: language)?.validated == false { return .originalEn }
        return instrument.wording(in: language)?.validated == false ? .unvalidatedTranslation : .validated
    }

    /// The submit's `englishOriginal`: `true` when the reader answered in the
    /// switched-to English original and the server reads the field; otherwise
    /// left out, so an older server's schema never sees it.
    func englishOriginalField() -> Bool? {
        guard showsEnglishOriginal, translationIsUnvalidated, language != .en,
              KnownServerVersion.isAtLeast(Self.englishOriginalMinimumServerVersion, defaults: serverDefaults) else { return nil }
        return true
    }
}
