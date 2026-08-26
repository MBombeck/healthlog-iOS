import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

@Suite("LogSanitizer")
struct LogSanitizerTests {
    @Test("Bearer tokens are redacted")
    func bearer() {
        let raw = "Authorization: Bearer hlk_abcdef0123456789abcdef0123456789"
        let s = LogSanitizer.redact(raw)
        #expect(!s.contains("hlk_"))
        #expect(s.contains("[redacted-bearer]"))
    }

    @Test("Email addresses are redacted")
    func email() {
        let raw = "User logged in: anna@example.org"
        let s = LogSanitizer.redact(raw)
        #expect(!s.contains("@"))
        #expect(s.contains("[redacted-email]"))
    }

    @Test("Long tokens are redacted")
    func longToken() {
        let token = String(repeating: "a", count: 64)
        let s = LogSanitizer.redact("token: \(token)")
        #expect(!s.contains(token))
    }

    // MARK: - H-2: UUID redaction (canonical 8-4-4-4-12 form)

    @Test("Lowercase UUID is redacted")
    func uuidLowercase() {
        let raw = "Idempotency-Key: a1b2c3d4-e5f6-7890-1234-567890abcdef"
        let s = LogSanitizer.redact(raw)
        #expect(!s.contains("a1b2c3d4-e5f6-7890-1234-567890abcdef"))
        #expect(s.contains("[redacted-uuid]"))
    }

    @Test("Uppercase UUID is redacted")
    func uuidUppercase() {
        let raw = "id=A1B2C3D4-E5F6-7890-1234-567890ABCDEF"
        let s = LogSanitizer.redact(raw)
        #expect(!s.contains("A1B2C3D4-E5F6-7890-1234-567890ABCDEF"))
        #expect(s.contains("[redacted-uuid]"))
    }

    @Test("Mixed-case UUID is redacted")
    func uuidMixedCase() {
        let raw = "key: a1B2c3D4-e5F6-7890-1234-567890aBcDeF"
        let s = LogSanitizer.redact(raw)
        #expect(!s.contains("a1B2c3D4-e5F6-7890-1234-567890aBcDeF"))
        #expect(s.contains("[redacted-uuid]"))
    }

    @Test("Multiple UUIDs in one message are all redacted")
    func uuidMultiple() {
        let one = "11111111-2222-3333-4444-555555555555"
        let two = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let s = LogSanitizer.redact("op \(one) → \(two)")
        #expect(!s.contains(one))
        #expect(!s.contains(two))
        #expect(s.components(separatedBy: "[redacted-uuid]").count - 1 == 2)
    }

    // MARK: - H-4: URL stripping (preserve scheme + host, drop path/query/fragment)

    @Test("URL with path and query is stripped to host")
    func urlWithPathQuery() {
        let raw = "GET https://api.example.org/v1/measurements?from=2026-01-01&token=abc failed"
        let s = LogSanitizer.redact(raw)
        #expect(s.contains("https://api.example.org"))
        #expect(!s.contains("/v1/measurements"))
        #expect(!s.contains("?from"))
        #expect(!s.contains("token=abc"))
    }

    @Test("URL with fragment is stripped to host")
    func urlWithFragment() {
        let raw = "Redirect → https://example.org/page#section"
        let s = LogSanitizer.redact(raw)
        #expect(s.contains("https://example.org"))
        #expect(!s.contains("#section"))
        #expect(!s.contains("/page"))
    }

    @Test("Bare URL (scheme + host only) passes through unchanged")
    func urlHostOnly() {
        let raw = "Connecting to https://api.example.org now"
        let s = LogSanitizer.redact(raw)
        #expect(s.contains("https://api.example.org"))
        #expect(s == raw)
    }

    @Test("HTTP scheme is preserved")
    func urlHTTP() {
        let raw = "fallback http://localhost:8080/api/health"
        let s = LogSanitizer.redact(raw)
        #expect(s.contains("http://localhost:8080"))
        #expect(!s.contains("/api/health"))
    }

    @Test("Multiple URLs in one message are all stripped")
    func urlMultiple() {
        let raw = "Migrate https://old.example.com/v1/data → https://new.example.com/v2/data"
        let s = LogSanitizer.redact(raw)
        #expect(s.contains("https://old.example.com"))
        #expect(s.contains("https://new.example.com"))
        #expect(!s.contains("/v1/data"))
        #expect(!s.contains("/v2/data"))
    }

    // MARK: - Pass-through

    @Test("Plain string without secrets passes through unchanged")
    func passThrough() {
        let raw = "Outbox-Replay startet (3 Operations)"
        let s = LogSanitizer.redact(raw)
        #expect(s == raw)
    }

    @Test("German plain text without secrets passes through")
    func passThroughGerman() {
        let raw = "Op createMeasurement erfolgreich repliziert"
        let s = LogSanitizer.redact(raw)
        #expect(s == raw)
    }

    @Test("Short hex string (below token threshold, not UUID) passes through")
    func passThroughShortHex() {
        let raw = "version 1.2.3 build deadbeef"
        let s = LogSanitizer.redact(raw)
        #expect(s == raw)
    }

    // MARK: - W1-5: cuid-style entity-ID redaction (below the {32,} token floor)

    @Test("med_ cuid entity id is redacted")
    func cuidMedIDRedacted() {
        let id = "med_clreabc123def456ghi789"
        let s = LogSanitizer.redact("card-compliance refreshed med=\(id) rate7=42")
        #expect(!s.contains(id))
        #expect(s.contains("[redacted-id]"))
        // Surrounding non-secret content survives.
        #expect(s.contains("card-compliance refreshed"))
        #expect(s.contains("rate7=42"))
    }

    @Test("mood_ / pr_ / meas_ cuid entity ids are all redacted")
    func cuidVariousPrefixesRedacted() {
        for id in ["mood_az0123456789abcdef01234", "pr_clx9k2m3n4p5q6r7s8t9u0v1", "meas_clabc123def456ghi789jk"] {
            let s = LogSanitizer.redact("entity \(id) processed")
            #expect(!s.contains(id), "id \(id) leaked")
            #expect(s.contains("[redacted-id]"))
        }
    }

    @Test("W1-5 cuid pattern does NOT over-redact 20–31 char prose / compounds")
    func cuidRedactionDoesNotOverRedactProse() {
        // The W1-5 fix must NOT regress to the rejected flat-`{20,}`-floor
        // approach. Lowering the generic token floor to 20 would have
        // swallowed long German compounds + 20–31 char identifiers as
        // `[redacted-token]`. The dedicated cuid pattern leaves them ALONE —
        // every line below (each ≤ 31 contiguous chars, i.e. below the
        // pre-existing `{32,}` token rule) MUST pass through verbatim, proving
        // the W1-5 change did not lower the floor.
        let cleanLines = [
            "Outbox-Replay startet (3 Operations)",
            "Op createMeasurement erfolgreich repliziert",
            "version 1.2.3 build deadbeef",
            "Medikamenteneinnahmeerinnerung gestellt", // 30-char compound
            "Datenschutzgrundverordnung aktiv", // 26-char compound
            "Geschwindigkeitsbegrenzung erreicht", // 26-char compound
            "createMedicationReminder dispatched" // 24-char camelCase
        ]
        for line in cleanLines {
            let s = LogSanitizer.redact(line)
            #expect(s == line, "over-redacted: \(line) → \(s)")
        }
    }

    @Test("W1-5 cuid pattern does not false-positive on long non-cuid identifiers")
    func cuidPatternNoFalsePositiveOnLongIdentifiers() {
        // Type names + snake_case identifiers ≥ 32 chars are redacted by the
        // PRE-EXISTING `{32,}` token rule (accepted behaviour — unchanged by
        // W1-5). The point this guards is narrower: the new cuid rule must not
        // be the thing that fires on them (no `[redacted-id]`), so the cuid
        // pattern stays scoped to the real `<prefix>_<cuid2>` entity-ID shape
        // and never grabs mixed-case type names or multi-underscore tokens.
        let longIdentifiers = [
            "HealthKitStatisticsSyncCoordinator", // 34 — camelCase type name
            "NotificationServiceMedicationActionTests", // 40 — camelCase type name
            "this_is_a_long_snake_case_identifier" // 36 — multi-underscore snake_case
        ]
        for ident in longIdentifiers {
            let s = LogSanitizer.redact(ident)
            #expect(!s.contains("[redacted-id]"), "cuid rule false-positive on: \(ident)")
        }
    }

    @Test("HLLogMessage interpolation redacts a cuid id tagged .public")
    func cuidInterpolationRedacted() {
        let id = "med_clreabc123def456ghi789"
        let msg: HLLogMessage = "schedule failed medId=\(id, privacy: .public)"
        #expect(!msg.sanitized.contains(id))
        #expect(msg.sanitized.contains("[redacted-id]"))
    }

    // MARK: - Idempotency / composition

    @Test("Redacting an already-redacted string is idempotent")
    func idempotent() {
        let raw = "Bearer abcdef1234567890abcdef1234567890ab and id a1b2c3d4-e5f6-7890-1234-567890abcdef"
        let once = LogSanitizer.redact(raw)
        let twice = LogSanitizer.redact(once)
        #expect(once == twice)
    }
}

// MARK: - HLLogger / HLLogMessage

@Suite("HLLogMessage")
struct HLLogMessageTests {
    @Test("String literal sanitizes on access")
    func stringLiteral() {
        let msg: HLLogMessage = "Bearer hlk_abcdef0123456789abcdef0123456789ab"
        #expect(!msg.sanitized.contains("hlk_"))
        #expect(msg.sanitized.contains("[redacted-bearer]"))
    }

    @Test("Interpolation with privacy tag sanitizes")
    func interpolationWithPrivacy() {
        let url = "https://api.example.org/v1/measurements?token=secret"
        let msg: HLLogMessage = "Request to \(url, privacy: .public) failed"
        #expect(msg.sanitized.contains("https://api.example.org"))
        #expect(!msg.sanitized.contains("/v1/measurements"))
        #expect(!msg.sanitized.contains("token=secret"))
    }

    @Test("Interpolation with Int (count) preserved")
    func interpolationInt() {
        let count = 42
        let msg: HLLogMessage = "Outbox-Replay startet (\(count, privacy: .public) Operations)"
        #expect(msg.sanitized == "Outbox-Replay startet (42 Operations)")
    }

    @Test("UUID interpolated in message is redacted")
    func interpolationUUID() {
        let id = "a1b2c3d4-e5f6-7890-1234-567890abcdef"
        let msg: HLLogMessage = "Op \(id, privacy: .public) verworfen"
        #expect(!msg.sanitized.contains(id))
        #expect(msg.sanitized.contains("[redacted-uuid]"))
    }

    // MARK: - M-7: OSLogPrivacy passthrough

    @Test("String literal alone → containsPrivateData is false")
    func privacyDefaultsPublicForLiterals() {
        let msg: HLLogMessage = "Plain literal"
        #expect(!msg.containsPrivateData)
    }

    @Test(".public interpolation keeps containsPrivateData false")
    func publicInterpolationStaysPublic() {
        let count = 42
        let msg: HLLogMessage = "count=\(count, privacy: .public)"
        #expect(!msg.containsPrivateData)
    }

    @Test(".private interpolation flips containsPrivateData to true")
    func privateInterpolationFlipsBoundary() {
        let token = "hlk_secret_token_at_least_thirtytwo_chars_long_xyz"
        let msg: HLLogMessage = "token=\(token, privacy: .private)"
        #expect(msg.containsPrivateData)
        // Sanitizer still runs as defence-in-depth — a long token gets caught
        // even on .private (operator-debug captures with redaction disabled).
        #expect(!msg.sanitized.contains(token))
        #expect(msg.sanitized.contains("[redacted-token]"))
    }

    @Test(".sensitive interpolation flips containsPrivateData to true")
    func sensitiveInterpolationFlipsBoundary() {
        let email = "user@example.com"
        let msg: HLLogMessage = "email=\(email, privacy: .sensitive)"
        #expect(msg.containsPrivateData)
    }

    @Test(".auto interpolation flips containsPrivateData to true")
    func autoInterpolationFlipsBoundary() {
        let payload = "opaque"
        let msg: HLLogMessage = "data=\(payload, privacy: .auto)"
        #expect(msg.containsPrivateData)
    }

    @Test("Mixed .public + .private message stays .private at OS level")
    func mixedPrivacyEscalates() {
        let count = 3
        let token = "sensitive"
        let msg: HLLogMessage = "count=\(count, privacy: .public), token=\(token, privacy: .private)"
        #expect(msg.containsPrivateData)
    }

    @Test("Int with .private privacy still flips boundary")
    func intPrivateFlipsBoundary() {
        let userId = 42
        let msg: HLLogMessage = "uid=\(userId, privacy: .private)"
        #expect(msg.containsPrivateData)
    }

    // MARK: - v0.13 W2: BYO-key (LLM provider) redaction

    @Test("OpenAI sk- key is redacted")
    func openAIKey() {
        let key = "sk-proj-abcDEF0123456789ghijKLMN"
        let s = LogSanitizer.redact("calling provider with key \(key)")
        #expect(!s.contains(key))
        #expect(s.contains("[redacted-llm-key]"))
    }

    @Test("Anthropic sk-ant- key is redacted")
    func anthropicKey() {
        let key = "sk-ant-api03-AbCdEf0123456789-XyZ_wvu"
        let s = LogSanitizer.redact("x-api-key header was \(key)")
        #expect(!s.contains(key))
        #expect(s.contains("[redacted-llm-key]"))
    }

    @Test("x-api-key header value is redacted, name preserved")
    func xApiKeyHeader() {
        let s = LogSanitizer.redact("x-api-key: sk-ant-secretvalue123")
        #expect(!s.contains("sk-ant-secretvalue123"))
        #expect(s.lowercased().contains("x-api-key"))
        #expect(s.contains("[redacted-llm-key]"))
    }

    @Test("x-goog-api-key header value (Gemini) is redacted")
    func googApiKeyHeader() {
        let s = LogSanitizer.redact("x-goog-api-key: AIzaSyD-9verySecretGeminiKey0000")
        #expect(!s.contains("AIzaSyD-9verySecretGeminiKey0000"))
        #expect(s.contains("[redacted-llm-key]"))
    }

    @Test("authorization: Bearer LLM key is redacted")
    func authorizationBearer() {
        let s = LogSanitizer.redact("Authorization: Bearer sk-proj-0123456789abcdefghijklmn")
        #expect(!s.contains("sk-proj-0123456789abcdefghijklmn"))
    }
}
