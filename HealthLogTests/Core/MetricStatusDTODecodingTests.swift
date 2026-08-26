import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the wire shape of `/api/insights/{metric}-status` against the
/// server contract (`src/lib/insights/{blood-pressure,weight,pulse,mood,bmi,medication-compliance}-status.ts`).
///
/// Pre-v0.4.0 the iOS DTO `MetricStatusEnvelope` expected
/// `{ recommendations: [Insight] }` — a fictional shape. Decoding silently
/// threw `keyNotFound("recommendations")` so "Befunde" never rendered on
/// any drill-down (A1-Audit §3.4, A4-Audit row 1).
@Suite("MetricStatusDTO wire shape")
struct MetricStatusDTODecodingTests {
    @Test("hasProvider=true + cached=false + text + updatedAt")
    func happyPath() throws {
        let json = Data(#"""
        {
            "hasProvider": true,
            "text": "Dein Blutdruck war zuletzt im Zielbereich.",
            "cached": false,
            "updatedAt": "2026-05-15T10:30:00.000Z"
        }
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MetricStatusDTO.self, from: json)
        #expect(dto.hasProvider == true)
        #expect(dto.text == "Dein Blutdruck war zuletzt im Zielbereich.")
        #expect(dto.cached == false)
        #expect(dto.updatedAt != nil)
    }

    @Test("hasProvider=false — no provider configured")
    func noProvider() throws {
        let json = Data(#"""
        {
            "hasProvider": false,
            "text": "Kein KI-Provider konfiguriert.",
            "cached": false,
            "updatedAt": null
        }
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MetricStatusDTO.self, from: json)
        #expect(dto.hasProvider == false)
        #expect(dto.text == "Kein KI-Provider konfiguriert.")
        #expect(dto.updatedAt == nil)
    }

    @Test("cached=true with previous updatedAt")
    func cachedHit() throws {
        let json = Data(#"""
        {
            "hasProvider": true,
            "text": "Cached AI summary.",
            "cached": true,
            "updatedAt": "2026-05-14T22:11:00.000Z"
        }
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MetricStatusDTO.self, from: json)
        #expect(dto.cached == true)
    }

    @Test("text:null is tolerated (future-proofing)")
    func nullText() throws {
        let json = Data(#"""
        {
            "hasProvider": true,
            "text": null,
            "cached": false,
            "updatedAt": "2026-05-15T10:30:00.000Z"
        }
        """#.utf8)
        let dto = try JSONDecoder.hlDefault.decode(MetricStatusDTO.self, from: json)
        #expect(dto.text == nil)
    }

    // MARK: - v0.11 W46 — current server contract (apiSuccess envelope + SWR extras)

    /// The metric-status routes now wrap the result in `apiSuccess(result)` →
    /// `{ data: <result>, error: null }` (server `src/lib/api-response.ts`), and
    /// the result carries the stale-while-revalidate extras
    /// (`preparing` / `revalidating` / `insufficient`,
    /// `src/lib/insights/metric-status.ts:MetricStatusResult`). This locks that
    /// the `APIEnvelope<MetricStatusDTO>` path `APIClient.decodePayload` uses
    /// decodes the CURRENT BP body — the inner DTO keys are unchanged, so the
    /// extra fields are ignored harmlessly and the assessment text surfaces.
    @Test("current server envelope (data wrapper + SWR extras) decodes the inner DTO")
    func currentEnvelopeWithExtras() throws {
        let body = Data(#"""
        {
            "data": {
                "hasProvider": true,
                "text": "Ihr Blutdruck liegt im Zielbereich.",
                "cached": true,
                "updatedAt": "2026-06-02T08:15:30.000Z",
                "preparing": false,
                "revalidating": false
            },
            "error": null
        }
        """#.utf8)
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body)
        #expect(envelope.error == nil)
        let dto = try #require(envelope.data)
        #expect(dto.hasProvider == true)
        #expect(dto.text == "Ihr Blutdruck liegt im Zielbereich.")
        #expect(dto.cached == true)
        #expect(dto.updatedAt != nil)
    }

    /// The read-only "preparing" miss: provider present, no last-good text yet.
    /// The card renders its skeleton (W46) rather than an empty/ready arm.
    @Test("preparing envelope (no text yet) decodes with hasProvider:true + text:null")
    func preparingEnvelope() throws {
        let body = Data(#"""
        {
            "data": {
                "hasProvider": true,
                "text": null,
                "cached": false,
                "updatedAt": null,
                "preparing": true,
                "revalidating": false
            },
            "error": null
        }
        """#.utf8)
        let envelope = try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body)
        let dto = try #require(envelope.data)
        #expect(dto.hasProvider == true)
        #expect(dto.text == nil)
    }

    // MARK: - Task #50 — SWR signal decode + lifecycle classification

    /// The cold-cache `preparing` body MUST decode its `preparing` flag (iOS
    /// previously dropped it → the card self-suppressed → text never surfaced).
    @Test("preparing:true decodes the flag and classifies as isPreparing")
    func preparingFlagDrivesPolling() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"preparing":true,"revalidating":false},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.preparing == true)
        #expect(dto.hasReadyText == false)
        #expect(dto.isPreparing == true, "a provider-present, text-null preparing body must keep the card polling")
    }

    /// `insufficient:true` (no readings) is terminal — the card shows the calm
    /// state and the caller stops polling.
    @Test("insufficient:true decodes the flag and is NOT preparing (terminal)")
    func insufficientIsTerminal() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":null,"cached":false,"updatedAt":null,"insufficient":true},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.insufficient == true)
        #expect(dto.isPreparing == false, "no-data metric must not poll — server already skipped the provider")
    }

    /// `revalidating:true` with last-good text already present: paint the prose
    /// immediately AND keep polling for the warmed upgrade (web parity).
    @Test("revalidating:true with last-good text is ready AND keeps polling")
    func revalidatingWithLastGoodTextPaintsAndPolls() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":"Gestern stabil.","cached":true,"updatedAt":"2026-06-01T07:00:00.000Z","preparing":false,"revalidating":true},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasReadyText == true)
        #expect(dto.isPreparing == true, "stale-but-served text must keep polling until the fresh row lands")
    }

    /// A terminal ready body (no in-flight refresh) stops the poll.
    @Test("ready text with no revalidate flag is terminal (stops polling)")
    func readyTerminalStopsPolling() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":"Im Zielbereich.","cached":true,"updatedAt":null},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasReadyText == true)
        #expect(dto.isPreparing == false)
    }

    /// No-provider is always terminal regardless of any preparing flag.
    @Test("hasProvider:false is never preparing (hidden, never polled)")
    func noProviderNeverPolls() throws {
        let body = Data(#"""
        {"data":{"hasProvider":false,"text":"Assistent deaktiviert.","cached":true,"updatedAt":null,"preparing":true},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasProvider == false)
        #expect(dto.isPreparing == false)
    }

    /// Whitespace-only text is NOT ready text (defends against a blank prose row).
    @Test("whitespace-only text is not ready text")
    func whitespaceTextNotReady() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":"   ","cached":false,"updatedAt":null,"preparing":true},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasReadyText == false)
        #expect(dto.isPreparing == true)
    }

    // MARK: - b177 W-ASSESS2 — tolerant-first decode (fetch survives field drift)

    /// A body WITHOUT `hasProvider` must still decode (default `true`) and
    /// surface its prose. Pre-b177 this threw `keyNotFound("hasProvider")`,
    /// which `APIClient.decodePayload`'s `try?`-envelope arm masked as a
    /// top-level keyNotFound — and the whole per-metric Einschätzung died.
    @Test("missing hasProvider decodes with default true and keeps the prose")
    func missingHasProviderDefaultsTrue() throws {
        let body = Data(#"""
        {"data":{"text":"Dein Puls war zuletzt stabil.","cached":true,"updatedAt":"2026-06-11T08:00:00.000Z"},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasProvider == true)
        #expect(dto.hasReadyText == true)
        #expect(dto.text == "Dein Puls war zuletzt stabil.")
    }

    /// Unknown ADDITIVE fields (newer server) decode harmlessly — the closed
    /// CodingKeys set ignores them. Locks the v1.16.x enriched-status forward
    /// compatibility.
    @Test("unknown additive fields are ignored (newer server)")
    func unknownAdditiveFieldsIgnored() throws {
        let body = Data(#"""
        {"data":{"hasProvider":true,"text":"Im Zielbereich.","cached":false,"updatedAt":null,
        "signalBlock":{"score":82,"trend":"up"},"normalRange":{"low":60,"high":80},"futureKey":[1,2,3]},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasReadyText == true)
    }

    /// A drifted `updatedAt` (non-ISO string or wrong type) must cost only the
    /// provenance timestamp — never the whole body. Pre-b177 the custom date
    /// strategy threw and sank the entire fetch.
    @Test("unparseable updatedAt degrades to nil instead of killing the decode")
    func driftedUpdatedAtDegradesToNil() throws {
        for raw in [#""2026-06-11 08:00:00""#, "1760169600000", "true"] {
            let body = Data(#"""
            {"data":{"hasProvider":true,"text":"Prosa bleibt.","cached":true,"updatedAt":\#(raw)},"error":null}
            """#.utf8)
            let dto = try #require(
                try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
            )
            #expect(dto.updatedAt == nil)
            #expect(dto.hasReadyText == true, "prose must survive a drifted updatedAt (\(raw))")
        }
    }

    /// Wrong-typed boolean flags degrade to their defaults, never a throw.
    @Test("wrong-typed flags degrade to defaults")
    func wrongTypedFlagsDegrade() throws {
        let body = Data(#"""
        {"data":{"hasProvider":"yes","text":"Bleibt lesbar.","cached":"nope","preparing":1},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasProvider == true)
        #expect(dto.cached == false)
        #expect(dto.preparing == false)
        #expect(dto.hasReadyText == true)
    }

    /// An explicit `hasProvider:false` is still honoured verbatim — tolerance
    /// must not erase the real no-provider arm (the hint/no-provider render
    /// path and the no-provider cache bypass both depend on it).
    @Test("explicit hasProvider:false still decodes as false")
    func explicitFalseStillFalse() throws {
        let body = Data(#"""
        {"data":{"hasProvider":false,"text":"Kein KI-Schlüssel hinterlegt.","cached":true,"updatedAt":null},"error":null}
        """#.utf8)
        let dto = try #require(
            try JSONDecoder.hlDefault.decode(APIEnvelope<MetricStatusDTO>.self, from: body).data
        )
        #expect(dto.hasProvider == false)
        #expect(dto.isPreparing == false)
    }
}

/// MetricKind alignment with server kindEnum (A4-Audit row 5 + row 20).
@Suite("MetricKind raw values match server kindEnum")
struct MetricKindRawValueTests {
    @Test("Sleep / Steps cases exist and have correct raw values")
    func newCases() {
        #expect(MetricKind.sleep.rawValue == "sleep")
        #expect(MetricKind.steps.rawValue == "steps")
    }

    @Test("Renamed raw values for spo2 / bodyWater match server")
    func renamedRaws() {
        #expect(MetricKind.spo2.rawValue == "oxygenSaturation")
        #expect(MetricKind.bodyWater.rawValue == "totalBodyWater")
    }

    @Test("All canonical server kinds round-trip from JSON")
    func roundTrip() throws {
        let serverKinds = [
            "weight", "bloodPressure", "pulse", "glucose", "bodyFat",
            "oxygenSaturation", "totalBodyWater", "boneMass", "sleep", "steps"
        ]
        for raw in serverKinds {
            let json = Data("\"\(raw)\"".utf8)
            let kind = try JSONDecoder.hlDefault.decode(MetricKind.self, from: json)
            #expect(kind.rawValue == raw)
        }
    }

    @Test("TolerantMetricKind decodes unknown server kinds as nil")
    func tolerantDecodingSurvivesUnknown() throws {
        let json = Data("\"futureMetric_v999\"".utf8)
        let tolerant = try JSONDecoder.hlDefault.decode(TolerantMetricKind.self, from: json)
        #expect(tolerant.value == nil)
    }

    @Test("TolerantMetricKind decodes known kinds correctly")
    func tolerantDecodingKnown() throws {
        let json = Data("\"sleep\"".utf8)
        let tolerant = try JSONDecoder.hlDefault.decode(TolerantMetricKind.self, from: json)
        #expect(tolerant.value == .sleep)
    }
}
