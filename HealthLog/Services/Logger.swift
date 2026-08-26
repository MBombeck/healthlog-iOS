import Foundation
import os

// MARK: - LogSanitizer

//
// Aktive Redaktions-Regeln (Reihenfolge ist relevant — Bearer + URL vor Token,
// damit URL-Strip nicht die hex-Token aus der URL frisst):
//
//   1. Bearer-Header:        "Bearer <token>"  → "[redacted-bearer]"
//   2. URLs:                 "https://host/p?q=…" → "https://host"  (nur Scheme + Host)
//   3. Email-Adressen:       "name@example.tld"   → "[redacted-email]"
//   4. UUIDs (mit Bindestrich): canonical 8-4-4-4-12 → "[redacted-uuid]"
//      (Audit H-2 — Idempotency-Keys sind UUIDs und liefen vorher durch.)
//   5. cuid-förmige Entity-IDs: <prefix>_<cuid2> (z.B. med_/mood_/pr_) →
//      "[redacted-id]" — fängt die ~28-Zeichen-IDs ab, die unter der
//      {32,}-Token-Schwelle durchliefen (v0.12 W1, Security W1-5).
//   6. Token-ähnliche Strings: ≥32 Zeichen [A-Za-z0-9_-] → "[redacted-token]"
//
// Alle HLLog-Calls werden über `HLLogger` zentral durch `LogSanitizer.redact()`
// geführt, damit kein Call-Site eine Redaktion „vergessen“ kann (Audit H-3).
//
// Audit-Referenzen: Security H-2 (UUIDs), H-3 (Routing), H-4 (URL-Strip).
// Doku: docs/security.md  →  „Logging“-Abschnitt.

/// Sanitizer für Log-Messages. Entfernt Tokens, Authorization-Header-Werte,
/// Email-Adressen, UUIDs (z.B. Idempotency-Keys) und reduziert URLs auf Host.
public enum LogSanitizer {
    /// Compiled-once. NSRegularExpression ist threadsafe (Apple docs: it's safe to
    /// use a single instance from multiple threads), und stringByReplacingMatches
    /// ist re-entrant.
    private static let bearerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[Bb]earer\\s+[A-Za-z0-9._\\-]+",
        options: []
    )

    /// Match http/https URL inkl. optionalem Path/Query/Fragment. Wir capturen
    /// Scheme + Host getrennt, damit `replace(...)` die URL auf `scheme://host`
    /// reduziert (Audit H-4).
    private static let urlRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(https?)://([^/\\s?#]+)(?:[/?#][^\\s]*)?",
        options: []
    )

    private static let emailRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
        options: [.caseInsensitive]
    )

    /// Canonical UUID 8-4-4-4-12 hex (case-insensitive). Catches Idempotency-Keys
    /// und alle UUID-förmigen Identifier, die der `tokenLikeRegex` ({32,}) verfehlt,
    /// weil die Bindestriche die Run-Length brechen (Audit H-2).
    private static let uuidRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        options: []
    )

    /// cuid-style entity-ID matcher (v0.12 W1 — Security W1-5). Server entity
    /// IDs are `<lowercase-prefix>_<cuid2>` — e.g. `med_clre…`, `mood_az0…`,
    /// `pr_clx9…`. A cuid2 body is a lowercase base36 run (leading letter, then
    /// lowercase-alphanumeric, ~24 chars), so a `med_`+24-char id is ~28 chars
    /// — BELOW the `tokenLikeRegex` `{32,}` floor, which let it emit verbatim in
    /// sysdiagnose. We do NOT simply lower that floor to `{20,}`: a flat 20-char
    /// run over-redacts ordinary log prose — long German compounds
    /// (`Medikamenteneinnahmeerinnerung`) and camelCase type names
    /// (`HealthKitStatisticsSyncCoordinator`) would all turn into
    /// `[redacted-token]`, gutting debuggability. This dedicated pattern targets
    /// only the entity-ID *shape*: a short lowercase prefix (`[a-z]{1,8}_`)
    /// followed by a single contiguous ≥21-char lowercase-alphanumeric body
    /// (`[a-z][a-z0-9]{19,}`, no inner `_`/`-`), bounded by `\b`. That catches
    /// every `med_`/`mood_`/`pr_`/`meas_` id while leaving prose, snake_case
    /// identifiers, and mixed-case type names untouched (verified against a
    /// prose corpus in `LogSanitizerTests`).
    private static let entityIDRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\b[a-z]{1,8}_[a-z][a-z0-9]{19,}\\b",
        options: []
    )

    /// #57 — step-up elevation tokens (`hle_<64 hex>`). The generic
    /// `tokenLikeRegex` already swallows the ~68-char contiguous run, but a
    /// dedicated rule gives a clear marker AND defends a shorter/edge-cased
    /// value (a `hle_` head below the {32,} floor would otherwise leak). Matched
    /// BEFORE the generic sweep. The TOTP Base32 secret and recovery codes carry
    /// no distinctive shape, so their client-side guarantee is structural: they
    /// are never interpolated into a log line (mirroring the server's stance).
    private static let elevationTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bhle_[A-Za-z0-9]+",
        options: []
    )

    private static let tokenLikeRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?:[A-Za-z0-9_-]{32,})",
        options: []
    )

    /// v0.13 W2 — BYO-key (device→provider) LLM API-key shapes. Provider keys
    /// (OpenAI `sk-…` / `sk-proj-…`, Anthropic `sk-ant-…`) start with a short
    /// `sk-` prefix and run to a length BELOW the generic `tokenLikeRegex`
    /// `{32,}` floor only for the prefix segment — but the body is `-`-broken
    /// (`sk-proj-…`, `sk-ant-api03-…`), which fractures the contiguous
    /// `[A-Za-z0-9_-]{32,}` run and could let a key slip through verbatim. This
    /// dedicated pattern matches the whole `sk[-…]` shape (including the dashes)
    /// and redacts it BEFORE the generic token sweep. Bounded by a leading
    /// non-word boundary so it does not eat surrounding prose.
    private static let llmKeyRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\bsk-[A-Za-z0-9_-]{16,}",
        options: []
    )

    /// v0.13 W2 — provider auth header VALUES. `x-api-key` (Anthropic) and
    /// `x-goog-api-key` (Gemini) carry the raw key. We redact the value after
    /// the header name + colon, leaving the header NAME so a log line stays
    /// debuggable (`x-api-key: [redacted-llm-key]`).
    ///
    /// `authorization` is intentionally NOT matched here — ``bearerRegex`` (run
    /// first) already collapses `Authorization: Bearer <token>` to
    /// `[redacted-bearer]`, and re-matching the surviving `[redacted-bearer]`
    /// value would clobber that established marker (regression guard:
    /// `LogSanitizerTests.bearer`). `anthropic-version` is also excluded — its
    /// value is a fixed public date, not a secret, so redacting it only hurts
    /// debuggability.
    private static let providerHeaderRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?i)(x-api-key|x-goog-api-key)\\s*:\\s*[^\\s,;]+",
        options: []
    )

    public static func redact(_ raw: String) -> String {
        var s = raw
        s = replace(s, regex: bearerRegex, with: "[redacted-bearer]")
        // Provider auth-header values (x-api-key / x-goog-api-key / …) and the
        // sk-… key shape BEFORE the URL/token sweeps so the key never survives
        // a partial earlier match (v0.13 W2).
        s = replace(s, regex: providerHeaderRegex, with: "$1: [redacted-llm-key]")
        s = replace(s, regex: llmKeyRegex, with: "[redacted-llm-key]")
        // URL-Strip vor Token-Match: sonst frisst der {32,}-Match die Pfad-Segmente
        // mit, bevor wir auf Host kürzen können.
        s = replace(s, regex: urlRegex, with: "$1://$2")
        s = replace(s, regex: emailRegex, with: "[redacted-email]")
        s = replace(s, regex: uuidRegex, with: "[redacted-uuid]")
        // cuid-style entity IDs (med_/mood_/pr_/…) before the {32,} token
        // sweep — they sit below the token floor, so without this they'd
        // slip through (v0.12 W1 — Security W1-5).
        // #57 — step-up elevation (`hle_…`) FIRST, before both the entity-ID and
        // the generic token sweeps: an `hle_` token is long enough to also match
        // the ~28-char `entityIDRegex` ([redacted-id]), so it must claim its own
        // `[redacted-elevation]` marker before that rule swallows it.
        s = replace(s, regex: elevationTokenRegex, with: "[redacted-elevation]")
        s = replace(s, regex: entityIDRegex, with: "[redacted-id]")
        s = replace(s, regex: tokenLikeRegex, with: "[redacted-token]")
        return s
    }

    private static func replace(_ input: String, regex: NSRegularExpression?, with replacement: String) -> String {
        guard let regex else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}

// MARK: - HLLog

/// Zentrale Logger-Factory mit OSLog-Categories pro Subsystem.
/// Production: nur `info`+. **Jede Message** läuft durch `LogSanitizer.redact()`,
/// bevor sie an `os.Logger` weitergereicht wird (Audit H-3 — Routing-Garantie).
public enum HLLog {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "dev.healthlog.app"

    public static let api = HLLogger(subsystem: subsystem, category: "api")
    public static let auth = HLLogger(subsystem: subsystem, category: "auth")
    public static let healthKit = HLLogger(subsystem: subsystem, category: "healthkit")
    public static let storage = HLLogger(subsystem: subsystem, category: "storage")
    public static let outbox = HLLogger(subsystem: subsystem, category: "outbox")
    public static let cache = HLLogger(subsystem: subsystem, category: "cache")
    public static let ui = HLLogger(subsystem: subsystem, category: "ui")
    public static let security = HLLogger(subsystem: subsystem, category: "security")
    public static let notifications = HLLogger(subsystem: subsystem, category: "notifications")
    public static let watch = HLLogger(subsystem: subsystem, category: "watch")
}

// MARK: - HLLogger

/// Thin wrapper um `os.Logger` der **garantiert** alle Messages durch
/// `LogSanitizer.redact()` schickt. Das ersetzt die direkte `os.Logger`-Verwendung
/// als Call-Site-API: Jede Interpolation (`\(value, privacy: .public)`) sammelt
/// die Argumente, formatiert lokal, redacts, und reicht den finalen String an
/// `os.Logger` weiter.
///
/// **M-7 (v0.6.2) — privacy passthrough:** Call-Sites tagging `.private` (or
/// `.sensitive` / `.auto`) propagieren ihre Privacy-Intention jetzt ins OSLog —
/// the message goes out under `.private` at the OS level so `sysdiagnose`
/// captures redact die Zeile bei Nicht-Developer-Devices automatisch. Default-
/// Verhalten (alle Interpolations `.public`) bleibt unverändert. Der
/// `LogSanitizer` ist die Defence-in-Depth-Schicht und läuft weiterhin
/// vor dem OSLog-Call.
public struct HLLogger: Sendable {
    private let logger: os.Logger

    public init(subsystem: String, category: String) {
        logger = os.Logger(subsystem: subsystem, category: category)
    }

    // OSLogPrivacy is non-Sendable + we can only branch on it at the
    // os.Logger interpolation site (the privacy modifier must be a
    // compile-time literal). We use `HLLogMessage.containsPrivateData`
    // to pick the OS-level boundary. The sanitizer runs unconditionally,
    // so even .private messages would NOT leak tokens to a developer-
    // signed device that disabled OS-level redaction.

    public func debug(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.debug("\(message.sanitized, privacy: .private)")
        } else {
            logger.debug("\(message.sanitized, privacy: .public)")
        }
    }

    public func info(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.info("\(message.sanitized, privacy: .private)")
        } else {
            logger.info("\(message.sanitized, privacy: .public)")
        }
    }

    public func notice(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.notice("\(message.sanitized, privacy: .private)")
        } else {
            logger.notice("\(message.sanitized, privacy: .public)")
        }
    }

    public func warning(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.warning("\(message.sanitized, privacy: .private)")
        } else {
            logger.warning("\(message.sanitized, privacy: .public)")
        }
    }

    public func error(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.error("\(message.sanitized, privacy: .private)")
        } else {
            logger.error("\(message.sanitized, privacy: .public)")
        }
    }

    public func fault(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.fault("\(message.sanitized, privacy: .private)")
        } else {
            logger.fault("\(message.sanitized, privacy: .public)")
        }
    }

    public func critical(_ message: HLLogMessage) {
        if message.containsPrivateData {
            logger.critical("\(message.sanitized, privacy: .private)")
        } else {
            logger.critical("\(message.sanitized, privacy: .public)")
        }
    }
}

// MARK: - HLLogMessage

/// String-Literal + Interpolation-Empfänger. Akzeptiert die gleiche Syntax wie
/// `os.Logger` (`"... \(value, privacy: .public) ..."`), sammelt alle Teile als
/// String und liefert via `sanitized` die durch `LogSanitizer.redact()` geführte
/// Variante.
///
/// **M-7 (v0.6.2):** the interpolation now also tracks whether any segment
/// was tagged `.private`, `.sensitive`, or `.auto` so the OS-level privacy
/// boundary can be honoured (the OS hides `.private` payloads in
/// `sysdiagnose` for non-developer-signed devices). The sanitizer continues
/// to redact every message as defence-in-depth.
public struct HLLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var buffer: String
        /// True when at least one interpolation segment was tagged with a
        /// non-`.public` privacy (`.private`, `.sensitive`, `.auto`). Drives
        /// the OS-level masking choice in `HLLogger`.
        var hasNonPublicPrivacy: Bool = false

        public init(literalCapacity: Int, interpolationCount: Int) {
            buffer = ""
            buffer.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            buffer.append(literal)
        }

        /// Privacy-classifier — `.public` keeps the OS-level boundary at
        /// `.public`. Anything else (`.private`, `.sensitive`, `.auto`,
        /// `.auto(mask:)`) flips the message to `.private` at the OS level.
        /// String-comparison is the only available cross-version-safe way
        /// to peek inside `OSLogPrivacy` (Apple does not expose the cases).
        private static func isPublic(_ privacy: OSLogPrivacy) -> Bool {
            String(describing: privacy) == String(describing: OSLogPrivacy.public)
        }

        // MARK: Generic interpolations

        public mutating func appendInterpolation(_ value: some CustomStringConvertible) {
            buffer.append(value.description)
        }

        public mutating func appendInterpolation(_ value: some CustomStringConvertible, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(value.description)
        }

        public mutating func appendInterpolation(_ value: String) {
            buffer.append(value)
        }

        public mutating func appendInterpolation(_ value: String, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(value)
        }

        public mutating func appendInterpolation(_ value: Int) {
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Int, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: UInt) {
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: UInt, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Double) {
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Double, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Bool) {
            buffer.append(String(value))
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: OSLogPrivacy) {
            if !Self.isPublic(privacy) { hasNonPublicPrivacy = true }
            buffer.append(String(value))
        }
    }

    public var raw: String
    /// True when any interpolation in this message was tagged with a
    /// non-`.public` privacy. Drives the `os.Logger.<level>("\(...)", privacy:)`
    /// choice in `HLLogger`.
    public let containsPrivateData: Bool

    public init(stringLiteral value: String) {
        raw = value
        containsPrivateData = false
    }

    public init(stringInterpolation: Interpolation) {
        raw = stringInterpolation.buffer
        containsPrivateData = stringInterpolation.hasNonPublicPrivacy
    }

    /// Lazy-once. HLLogMessage-Instanzen sind kurzlebig (eine pro Log-Call) — wir
    /// sanitisieren erst beim Lesen, damit Debug-Builds bei deaktiviertem Level
    /// keinen Regex-Run zahlen.
    public var sanitized: String {
        LogSanitizer.redact(raw)
    }
}
