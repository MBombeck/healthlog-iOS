import Foundation
@testable import HealthLog
import Testing

/// **Phase 16 Plan 02 — the words on the first three screens (K3, K4).**
///
/// Both findings are the operator reading his own app: the trust-boundary
/// sheet's primary button says "Ich verstehe und fortfahren", which is a finite
/// clause bolted to an infinitive and reads machine-translated, and the
/// web-login hint runs two sentences where the CTA above it has already said
/// what the button does. This is the first surface a new user and an App Review
/// reviewer both see.
///
/// The values are read from the COMPILED catalogue (`de.lproj` / `en.lproj`) so
/// what is asserted is what ships, not what a JSON file happens to contain. The
/// length clause exists so "kurz" survives the next edit: a budget nobody wrote
/// down is a budget the next person silently spends.
@Suite("Phase 16 onboarding copy — grammar and length")
struct OnboardingCopyTests {
    /// The character ceiling for a one-line hint under a primary CTA.
    ///
    /// Not arbitrary: the string it replaces was 128 (DE) and 122 (EN)
    /// characters over two sentences, rendered `.hlCaption`, centred, under a
    /// full-width button. 100 leaves one comfortable line at default Dynamic
    /// Type and two at the accessibility sizes, and it is small enough that a
    /// second sentence cannot fit inside it by accident.
    static let hintBudget = 100

    /// The literal K3 was reported against. Named so the assertion below says
    /// what it refuses, rather than only what it wants.
    static let brokenConfirm = "Ich verstehe und fortfahren"

    // MARK: - K3

    @Test("the trust-boundary confirm button is grammatical German")
    func trustBoundaryConfirmIsGrammatical() throws {
        let de = try Self.value("onboarding.trustboundary.confirm", language: "de")
        let en = try Self.value("onboarding.trustboundary.confirm", language: "en")

        var violations: [String] = []
        if de == Self.brokenConfirm {
            violations.append("the German confirm button still reads \"\(Self.brokenConfirm)\"")
        }
        // A button label is not a sentence and does not end in one.
        if de.hasSuffix(".") { violations.append("a button label carries a full stop: \"\(de)\"") }
        if de.isEmpty || en.isEmpty { violations.append("the confirm button lost a localisation") }
        // DE and EN say the same thing in the same shape — a two-part
        // acknowledgement, not one language carrying a clause the other lacks.
        if de.contains(",") != en.contains(",") {
            violations.append("DE and EN no longer share the acknowledgement's shape: \"\(de)\" / \"\(en)\"")
        }

        #expect(
            violations.isEmpty,
            "EXPECTED_RED: the confirm button still reads Ich verstehe und fortfahren"
        )
    }

    // MARK: - K4

    @Test("the web-login hint is one short sentence in both languages")
    func webLoginHintIsShort() throws {
        var violations: [String] = []
        for language in ["de", "en"] {
            let hint = try Self.value("onboarding.webLogin.hint", language: language)
            if hint.count > Self.hintBudget {
                violations.append("\(language) hint is \(hint.count) characters, over the \(Self.hintBudget) budget")
            }
            if Self.sentenceCount(hint) > 1 {
                violations.append("\(language) hint is \(Self.sentenceCount(hint)) sentences, not one")
            }
            if hint.isEmpty { violations.append("\(language) hint is empty") }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: the hint is still two sentences")
    }

    // MARK: - K5, the polish half

    /// 13-02 fixed the race that made the fallback link a no-op. What it left
    /// here — deliberately, by name, in 13-CONTEXT — is that the control still
    /// did not read as one, and that the form it opened arrived without a caret.
    @Test("only a deliberate reveal carries the keyboard into the password form")
    func revealCarriesFocusOnlyForADeliberateOpen() {
        // The fallback link and the self-hosted passkey CTA: the form was not
        // showing, the user asked for it, the caret belongs in it.
        #expect(AuthStepFormVisibility.revealCarriesFocus(wasShowing: false))
        // A form that was already the primary door, or one `mayLatchOnAppear`
        // opened because no handoff CTA can still arrive, asked for nothing —
        // a keyboard raised over it would cover the CTA still being decided.
        #expect(!AuthStepFormVisibility.revealCarriesFocus(wasShowing: true))

        // And the two states it is asked about are the two the visibility rule
        // actually produces, so this cannot drift into testing a third thing.
        let handoff = AuthStepFormVisibility(prefersWebHandoff: true, availability: .available, latched: false)
        #expect(!handoff.showsEmailSection, "under a live handoff CTA the form is the fallback, and closed")
        let native = AuthStepFormVisibility(prefersWebHandoff: false, availability: .unavailable, latched: false)
        #expect(native.showsEmailSection, "everywhere else the form is the primary door and simply present")
    }

    @Test("the fallback link is an action, and the form it opens settles before it is focused")
    func fallbackLinkReadsAsAnActionAndSettlesBeforeFocusing() throws {
        let source = try Self.strippedSource("HealthLog/Screens/Onboarding/ServerAuthStep.swift")

        var violations: [String] = []
        // The defect: focus assigned in the same update that creates the field.
        // SwiftUI has nothing to move focus to yet and drops it silently.
        if source.contains("emailSectionLatched = true\n                        focused = .email") {
            violations.append("the reveal still sets focus in the tick that creates the field")
        }
        if !source.contains("pendingEmailFocus") {
            violations.append("no parked focus request survives the reveal")
        }
        if !source.contains("HLSheet.focusDelay") {
            violations.append("the form is focused without settling first")
        }
        // Both reveals go through one rule rather than two copies of it.
        let reveals = source.components(separatedBy: "revealEmailSection()").count - 1
        if reveals < 3 {
            violations.append("the reveal rule has \(reveals - 1) call sites; the fallback link and the passkey CTA are two")
        }
        // The affordance itself: primary ink and a real region, not caption-grey
        // text in the same colour as the hint two lines above it.
        if !source.contains("onboarding.webLogin.fallbackPassword") {
            violations.append("the fallback label left the catalogue")
        }
        if !source.contains("minHeight: 44") {
            violations.append("the fallback link states no minimum hit region")
        }

        #expect(violations.isEmpty, "the K5 affordance polish is incomplete: \(violations)")
    }

    // MARK: - Helpers

    /// How many sentences a hint runs to. A terminator followed by whitespace
    /// starts another one; a trailing terminator closes the last.
    static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var count = 0
        var previousWasTerminator = false
        for character in trimmed {
            if character == "." || character == "!" || character == "?" {
                previousWasTerminator = true
                continue
            }
            if previousWasTerminator, character == " " { count += 1 }
            previousWasTerminator = false
        }
        return count + 1
    }

    private static func value(_ key: String, language: String) throws -> String {
        let bundle = try lprojBundle(language: language)
        let resolved = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
        #expect(resolved != "MISSING", "\(key) has no \(language) value in the compiled catalogue")
        return resolved
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Source contracts read comment-stripped source — a doc comment naming a
    /// symbol is not the symbol.
    private static func strippedSource(_ relativePath: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        return stripLineComments(from: stripBlockComments(from: text))
    }

    private static func stripBlockComments(from source: String) -> String {
        var out = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound ..< rest.endIndex) else { return out }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    private static func stripLineComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var quoted = false
            var previous: Character = " "
            for (offset, character) in line.enumerated() {
                if character == "\"", previous != "\\" { quoted.toggle() }
                if !quoted, character == "/", previous == "/" { return String(line.prefix(offset - 1)) }
                previous = character
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func lprojBundle(language: String) throws -> Bundle {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else
        {
            throw CopyTestError.missingLproj(language: language)
        }
        return bundle
    }

    private enum CopyTestError: Error, CustomStringConvertible {
        case missingLproj(language: String)

        var description: String {
            switch self {
            case let .missingLproj(language):
                "Missing \(language).lproj in the host-app bundle — did the catalogue compile?"
            }
        }
    }
}
