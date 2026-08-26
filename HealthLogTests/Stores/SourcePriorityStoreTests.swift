import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0.5.3-F3 — `SourcePriorityStore` derivation contract.
///
/// Pins the metric-key set + label translation + row composition so the
/// read-only ladder card stays stable across waves. The store itself is a
/// thin wrapper over the actor repo; the meaningful behaviour is the
/// `metricEntries` derivative and the source-label translation.
///
/// v0.5.4-SP4: erweitert um Write-Path-Tests für den Editor —
/// `updateLadder(forMetric:to:)` + `resetToDefaults()` + Rollback-Verhalten.
@Suite("SourcePriorityStore — metric ladder derivation", .serialized)
@MainActor
struct SourcePriorityStoreTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.4",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeStore() -> SourcePriorityStore {
        SourcePriorityStore(repo: SourcePriorityRepository(api: makeAPI()))
    }

    @Test("Canonical metric keys mirror the web sources editor order")
    func canonicalMetricKeys() {
        // Web order from `sources-section.tsx`: steps → activeEnergy →
        // walkingRunningDistance → flightsClimbed → sleep → weight → ...
        let expected = [
            "steps",
            "activeEnergy",
            "walkingRunningDistance",
            "flightsClimbed",
            "sleep",
            "weight",
            "bloodPressure",
            "pulse",
            "bodyFat",
            "bodyTemperature",
            "spo2",
            "hrv",
            "restingHeartRate",
            "respiratoryRate",
            "skinTemperature",
            "vo2Max",
            "recovery",
            // Build 2 / 2.6 — closed the 17-vs-19 gap against the web editor.
            "stress",
            "sleepDebt"
        ]
        #expect(SourcePriorityStore.canonicalMetricKeys == expected)
        #expect(SourcePriorityStore.canonicalMetricKeys.count == 19, "web sources-section.tsx advertises 19 ladders")
    }

    @Test("stress + sleepDebt ladders match the server DEFAULT_SOURCE_PRIORITY verbatim")
    func stressAndSleepDebtLadders() {
        // `src/lib/validations/source-priority.ts:392,397` — a drifted default
        // would make the iOS "reset to default" write a different ladder than
        // the web reset for the same account.
        #expect(SourcePriorityStore.defaultLadder(forMetric: "stress") == ["OURA", "COMPUTED"])
        #expect(SourcePriorityStore.defaultLadder(forMetric: "sleepDebt") == ["WHOOP", "OURA", "POLAR", "COMPUTED"])
        // Both must be labelled — an unlabelled key falls back to `capitalized`
        // and would render "Sleepdebt" in the settings matrix.
        #expect(SourcePriorityStore.label(forMetricKey: "stress") == "Stress")
        #expect(SourcePriorityStore.label(forMetricKey: "sleepDebt") == "Schlafdefizit")
    }

    @Test("WHOOP signature metric keys are surfaced + labelled")
    func whoopSignatureMetricKeys() {
        // The recovery/respiratory/skin-temp ladders are WHOOP's whole point —
        // they must be in the canonical set so `metricEntries` iterates them.
        #expect(SourcePriorityStore.canonicalMetricKeys.contains("respiratoryRate"))
        #expect(SourcePriorityStore.canonicalMetricKeys.contains("skinTemperature"))
        #expect(SourcePriorityStore.canonicalMetricKeys.contains("recovery"))
        // Labels resolve (LocalizedStringKey-backed catalogue values).
        #expect(SourcePriorityStore.label(forMetricKey: "respiratoryRate") == "Respiratory rate")
        #expect(SourcePriorityStore.label(forMetricKey: "skinTemperature") == "Skin temperature")
        #expect(SourcePriorityStore.label(forMetricKey: "recovery") == "Recovery")
    }

    @Test("Metric-key labels resolve to the operator-approved catalogue strings")
    func metricKeyLabels() {
        #expect(SourcePriorityStore.label(forMetricKey: "steps") == "Steps")
        #expect(SourcePriorityStore.label(forMetricKey: "weight") == "Weight")
        #expect(SourcePriorityStore.label(forMetricKey: "bloodPressure") == "Blood pressure")
        #expect(SourcePriorityStore.label(forMetricKey: "hrv") == "Herzfrequenzvariabilität")
        #expect(SourcePriorityStore.label(forMetricKey: "vo2Max") == "VO₂ max")
        // Unknown keys pass through capitalised so the row never reads empty.
        // The exact transform isn't load-bearing — the contract is "never
        // empty / never the raw key".
        let unknown = SourcePriorityStore.label(forMetricKey: "newMetricToBeAdded")
        #expect(!unknown.isEmpty)
        #expect(unknown != "newMetricToBeAdded")
    }

    @Test("Source-token labels match the WorkoutDetailView mapping")
    func sourceTokenLabels() {
        #expect(SourcePriorityRow.displayLabel(forSource: "APPLE_HEALTH") == "Apple Health")
        #expect(SourcePriorityRow.displayLabel(forSource: "WITHINGS") == "Withings")
        // displayLabel feeds LocalizedStringKey, so MANUAL resolves to the
        // English catalogue key (renders "Manuell" for de via the de unit).
        #expect(SourcePriorityRow.displayLabel(forSource: "MANUAL") == "Manual")
        // Proper-noun sources match WorkoutDetailView.sourceLabel verbatim.
        #expect(SourcePriorityRow.displayLabel(forSource: "APPLE_HEALTH")
            == WorkoutDetailView.sourceLabel("APPLE_HEALTH"))
        #expect(SourcePriorityRow.displayLabel(forSource: "WITHINGS")
            == WorkoutDetailView.sourceLabel("WITHINGS"))
    }

    @Test("WHOOP/FITBIT/COMPUTED render as proper brand labels, not capitalized")
    func whoopFitbitSourceLabels() {
        // The old `.capitalized` fallback turned "WHOOP" into "Whoop" — these
        // explicit cases keep the brand casing consistent across every surface.
        #expect(SourcePriorityRow.displayLabel(forSource: "WHOOP") == "WHOOP")
        #expect(SourcePriorityRow.displayLabel(forSource: "FITBIT") == "Fitbit")
        #expect(SourcePriorityRow.displayLabel(forSource: "COMPUTED") == "Computed")
        // Case-insensitive on the wire token.
        #expect(SourcePriorityRow.displayLabel(forSource: "whoop") == "WHOOP")
    }

    // Default ladders mirror the server `DEFAULT_SOURCE_PRIORITY` map verbatim
    // (coord note `v1.12.0-server-to-ios-source-ladder-and-meds-ack.md`) so an
    // iOS "Reset to default" produces the same ladder as a web reset.

    @Test("Default-Ladder Weight: Withings first, then WHOOP/Fitbit tail")
    func defaultLadderWeight() {
        #expect(SourcePriorityStore.defaultLadder(forMetric: "weight")
            == ["WITHINGS", "APPLE_HEALTH", "MANUAL", "WHOOP", "FITBIT"])
        #expect(SourcePriorityStore.defaultLadder(forMetric: "bodyFat")
            == ["WITHINGS", "APPLE_HEALTH", "MANUAL", "FITBIT"])
    }

    @Test("Default-Ladder cumulative activity carries FITBIT")
    func defaultLadderCumulative() {
        #expect(SourcePriorityStore.defaultLadder(forMetric: "steps")
            == ["APPLE_HEALTH", "WITHINGS", "FITBIT", "MANUAL"])
        #expect(SourcePriorityStore.defaultLadder(forMetric: "activeEnergy")
            == ["APPLE_HEALTH", "WITHINGS", "FITBIT", "MANUAL"])
    }

    @Test("Default-Ladder recovery inputs put WHOOP first")
    func defaultLadderRecoveryInputs() {
        let expected = ["WHOOP", "FITBIT", "APPLE_HEALTH", "WITHINGS"]
        #expect(SourcePriorityStore.defaultLadder(forMetric: "sleep") == expected)
        #expect(SourcePriorityStore.defaultLadder(forMetric: "hrv") == expected)
        #expect(SourcePriorityStore.defaultLadder(forMetric: "restingHeartRate") == expected)
        #expect(SourcePriorityStore.defaultLadder(forMetric: "respiratoryRate") == expected)
    }

    @Test("Default-Ladder recovery + skinTemperature + bloodPressure match server map")
    func defaultLadderSpecialMetrics() {
        #expect(SourcePriorityStore.defaultLadder(forMetric: "recovery") == ["WHOOP", "COMPUTED"])
        #expect(SourcePriorityStore.defaultLadder(forMetric: "skinTemperature")
            == ["WITHINGS", "WHOOP", "FITBIT", "APPLE_HEALTH"])
        #expect(SourcePriorityStore.defaultLadder(forMetric: "spo2")
            == ["WITHINGS", "WHOOP", "FITBIT", "APPLE_HEALTH", "MANUAL"])
        // bloodPressure intentionally carries NO WHOOP/FITBIT (neither reports BP).
        #expect(SourcePriorityStore.defaultLadder(forMetric: "bloodPressure")
            == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
    }

    @Test("Canonical Source-Tokens enthält alle zehn Wire-Tokens inkl. WHOOP/FITBIT/OURA/POLAR/NIGHTSCOUT/STRAVA")
    func canonicalSourceTokens() {
        #expect(SourcePriorityStore.canonicalSourceTokens
            == ["APPLE_HEALTH", "WITHINGS", "WHOOP", "FITBIT", "OURA", "POLAR", "NIGHTSCOUT", "STRAVA", "MANUAL", "IMPORT"])
    }

    @Test("DTO round-trips respiratoryRate/skinTemperature/recovery — no silent drop")
    func dtoRoundTripsWhoopMetrics() {
        let store = makeStore()
        var dto = SourcePriorityDTO()
        for key in ["respiratoryRate", "skinTemperature", "recovery"] {
            dto = store.mutating(dto, settingLadder: SourcePriorityStore.defaultLadder(forMetric: key), forMetric: key)
        }
        // Flat + nested both populated → survives a PUT round-trip.
        #expect(dto.respiratoryRate == ["WHOOP", "FITBIT", "APPLE_HEALTH", "WITHINGS"])
        #expect(dto.metricPriority?.skinTemperature == ["WITHINGS", "WHOOP", "FITBIT", "APPLE_HEALTH"])
        #expect(dto.recovery == ["WHOOP", "COMPUTED"])
        #expect(dto.ladder(forMetric: "recovery") == ["WHOOP", "COMPUTED"])
    }

    @Test("mutating(_:settingLadder:forMetric:) hält flach + nested konsistent")
    func mutatingKeepsShapesAligned() {
        let store = makeStore()
        let next = store.mutating(
            SourcePriorityDTO(),
            settingLadder: ["WITHINGS", "APPLE_HEALTH", "MANUAL"],
            forMetric: "weight"
        )
        #expect(next.weight == ["WITHINGS", "APPLE_HEALTH", "MANUAL"], "flat alias must be set")
        #expect(next.metricPriority?.weight == ["WITHINGS", "APPLE_HEALTH", "MANUAL"], "nested key must be set")
        #expect(next.ladder(forMetric: "weight") == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
    }

    @Test("updateLadder(forMetric:to:) — Erfolgsfall echoed Server-Shape")
    func updateLadderHappyPath() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            // GET returns initial shape; PUT returns echoed shape.
            let body = Data(#"""
            {"data":{"weight":["APPLE_HEALTH","WITHINGS","MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        MockURLProtocol.handler = { req in
            // PUT echo
            let body = Data(#"""
            {"data":{"weight":["WITHINGS","APPLE_HEALTH","MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let ok = await store.updateLadder(forMetric: "weight", to: ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
        #expect(ok)
        #expect(store.error == nil)
        #expect(store.ladder?.ladder(forMetric: "weight") == ["WITHINGS", "APPLE_HEALTH", "MANUAL"])
    }

    @Test("updateLadder — 422-Fehler rollt auf vorigen Snapshot zurück")
    func updateLadderRollback() async {
        let store = makeStore()
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"weight":["APPLE_HEALTH","WITHINGS","MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        let before = store.ladder
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":null,"error":{"code":"VALIDATION","message":"bad shape"}}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, body)
        }
        let ok = await store.updateLadder(forMetric: "weight", to: ["BOGUS_TOKEN"])
        #expect(!ok)
        #expect(store.error != nil, "422 must surface as error")
        #expect(store.ladder == before, "ladder must roll back to pre-PUT snapshot")
    }

    @Test("resetToDefaults — PUTet jede Metric mit Default-Ladder")
    func resetToDefaultsHappyPath() async {
        let store = makeStore()
        // Initial GET — empty-ish ladder so we can prove the reset wrote.
        MockURLProtocol.handler = { req in
            let body = Data(#"""
            {"data":{"weight":["MANUAL"]},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        nonisolated(unsafe) var receivedBody: Data?
        nonisolated(unsafe) var method: String?
        MockURLProtocol.handler = { req in
            method = req.httpMethod
            if let stream = req.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 1024
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                buffer.deallocate()
                stream.close()
                receivedBody = data
            } else {
                receivedBody = req.httpBody
            }
            // Echo back a default-style shape so the store updates the cache.
            let echo = Data(#"""
            {"data":{"weight":["WITHINGS","APPLE_HEALTH","MANUAL"],"metricPriority":{"weight":["WITHINGS","APPLE_HEALTH","MANUAL"]}},"error":null}
            """#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, echo)
        }
        let ok = await store.resetToDefaults()
        #expect(ok)
        #expect(method == "PUT")
        // Body must include the canonical default for at least the weight key,
        // proving the store fed the server the full shape rather than a no-op.
        let bodyString = receivedBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #expect(bodyString.contains("WITHINGS"))
        #expect(bodyString.contains("APPLE_HEALTH"))
    }
}

// swiftlint:enable force_unwrapping
