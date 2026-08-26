import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif

#if canImport(HealthKit)

    /// Konvertiert `HKSample` → `HealthKitBatchEntryDTO`. Owner aller HK-spezifischen
    /// Wire-Konventionen die in `06-ios-responsibilities.md` und der A1-Audit-Tabelle
    /// festgehalten sind:
    ///
    /// - **×100-Konversion** für `oxygenSaturation` und `bodyFatPercentage` (HK liefert
    ///   0..1-Fraktionen, Server erwartet 0..100-Prozente).
    /// - **Sleep-Stage-Decoder** — `HKCategorySample` mit `sleepAnalysis` wird zu einer
    ///   Row mit `sleepStage = categorySample.value` (Codepoint 0..5) und
    ///   `value = (endDate - startDate) / 60` Minuten.
    /// - **`deviceType`-Mapper** auf Basis von `HKDevice.model` (Watch/Phone/Scale/...).
    /// - **Unit-String** je Identifier — Server-Side ist `unit` informativ aber required
    ///   (max 60 chars) und wird in `mapAppleHealthEntry()` gegen den Type-Erwartungswert
    ///   gechecked.
    public enum HealthKitWireConverter {
        /// Liefert eine oder mehrere Wire-Entries für ein einzelnes HK-Sample.
        /// - Quantity-Samples: genau eine Entry.
        /// - Category-Sleep-Sample: genau eine Entry mit `sleepStage`.
        /// - Andere Category-Types werden derzeit übersprungen (Server kennt sie nicht;
        ///   der Cursor-Advance kümmert sich darum, dass wir nicht endlos retryen).
        public static func entries(from sample: HKSample) -> [HealthKitBatchEntryDTO] {
            if let quantity = sample as? HKQuantitySample {
                if let entry = quantityEntry(quantity) {
                    return [entry]
                }
                return []
            }
            if let category = sample as? HKCategorySample,
               category.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            {
                return [sleepEntry(category)]
            }
            return []
        }

        // MARK: - Quantity-Samples

        private static func quantityEntry(_ sample: HKQuantitySample) -> HealthKitBatchEntryDTO? {
            let identifier = sample.quantityType.identifier
            guard let unit = preferredUnit(for: identifier) else {
                // Server kennt diesen Identifier eh nicht — wir lassen ihn raus,
                // damit der Anchor-Cursor nicht ins Leere zeigt. (Defensiv: das
                // sollte erst greifen, wenn Apple einen neuen QuantityType
                // einführt, für den wir noch keinen Eintrag haben.)
                return nil
            }
            let raw = sample.quantity.doubleValue(for: unit.hkUnit)
            let value = unit.scale * raw
            return HealthKitBatchEntryDTO(
                hkIdentifier: identifier,
                value: value,
                unit: unit.wireSymbol,
                startDate: sample.startDate,
                endDate: sample.endDate,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: deviceType(for: sample.device)
            )
        }

        // MARK: - Sleep

        private static func sleepEntry(_ sample: HKCategorySample) -> HealthKitBatchEntryDTO {
            // Dauer in Minuten als Double — der Server speichert Sleep-Duration
            // in Minuten (siehe `06-ios-responsibilities.md` Tabelle, "minutes" / sum-by-stage).
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            return HealthKitBatchEntryDTO(
                hkIdentifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
                value: minutes,
                unit: "min",
                startDate: sample.startDate,
                endDate: sample.endDate,
                sleepStage: sample.value,
                externalId: sample.uuid.uuidString,
                externalSourceVersion: sample.sourceRevision.productType,
                deviceType: deviceType(for: sample.device)
            )
        }

        // MARK: - Device-Type

        /// `HKDevice.model` → `HealthKitDeviceType`-Mapping. Heuristik anhand
        /// Apple's Modell-String (z. B. `"Apple Watch"`, `"iPhone"`, `"iPad"`) plus
        /// Hersteller-spezifische Aliase, soweit dokumentiert.
        ///
        /// Public, damit Tests den Mapper isoliert decken können ohne ein
        /// `HKQuantitySample` bauen zu müssen.
        public static func deviceType(for device: HKDevice?) -> HealthKitDeviceType {
            guard let device else { return .unknown }
            // 1) Bevorzugt Apple's Modell-String — ist das stabilste Signal.
            if let model = device.model {
                let lower = model.lowercased()
                if lower.contains("watch") { return .watch }
                if lower.contains("iphone") { return .phone }
                if lower.contains("ipad") { return .phone } // iPads zählen wir zu phone
                if lower.contains("scale") { return .scale }
                if lower.contains("ring") { return .ring }
                if lower.contains("band") { return .band }
            }
            // 2) Manche Drittanbieter (z. B. Withings via Health-Sync) setzen `name`
            //    statt `model`. Schwächeres Signal, aber besser als `unknown`.
            let name = device.name?.lowercased() ?? ""
            if name.contains("watch") { return .watch }
            if name.contains("iphone") || name.contains("ipad") { return .phone }
            if name.contains("scale") || name.contains("waage") { return .scale }
            if name.contains("ring") { return .ring }
            if name.contains("band") { return .band }
            return .unknown
        }

        // MARK: - Unit-Map

        /// Per-Identifier Unit-Konvention. Tuple aus dem realen `HKUnit` zum Lesen
        /// vom Sample und dem Server-erwarteten Wire-Symbol + Skalierungsfaktor.
        ///
        /// Public damit Tests die Unit-Tabelle gegen `06-ios-responsibilities.md`
        /// in einem CI-Drift-Check prüfen können.
        ///
        /// The flat per-identifier lookup trips `cyclomatic_complexity`; the
        /// trade-off is deliberate — a `[String: WireUnit]` dictionary would
        /// silently allow a missing identifier to compile, whereas this
        /// `switch` keeps every wire-unit row in one auditable table.
        public static func preferredUnit(for identifier: String) -> WireUnit? { // swiftlint:disable:this cyclomatic_complexity
            switch identifier {
            // Kg — Body-Mass-Familie
            case HKQuantityTypeIdentifier.bodyMass.rawValue:
                return WireUnit(hkUnit: .gramUnit(with: .kilo), wireSymbol: "kg", scale: 1)

            // % — Body-Fat (HK liefert 0..1, Server will 0..100)
            case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
                return WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 100)

            // °C — Body-Temperature
            case HKQuantityTypeIdentifier.bodyTemperature.rawValue:
                return WireUnit(hkUnit: .degreeCelsius(), wireSymbol: "degC", scale: 1)

            // mmHg — Blood-Pressure
            case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
                 HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
                return WireUnit(hkUnit: .millimeterOfMercury(), wireSymbol: "mmHg", scale: 1)

            // bpm — Pulse + RHR
            case HKQuantityTypeIdentifier.heartRate.rawValue,
                 HKQuantityTypeIdentifier.restingHeartRate.rawValue:
                return WireUnit(hkUnit: HKUnit.count().unitDivided(by: .minute()), wireSymbol: "bpm", scale: 1)

            // ms — HRV-SDNN
            case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
                return WireUnit(hkUnit: .secondUnit(with: .milli), wireSymbol: "ms", scale: 1)

            // br/min — Respiratory Rate (HK liefert count/min). Server-Enum
            // landing tracked unter `RESPIRATORY_RATE` — bis dahin
            // Skipped/unknown_hk_identifier akzeptiert.
            case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
                return WireUnit(hkUnit: HKUnit.count().unitDivided(by: .minute()), wireSymbol: "br/min", scale: 1)

            // % — Oxygen Saturation (HK liefert 0..1, Server will 0..100)
            case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
                return WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 100)

            // mg/dL — Blood Glucose
            case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
                return WireUnit(
                    hkUnit: HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci)),
                    wireSymbol: "mg/dL",
                    scale: 1
                )

            // count — Step Count + Flights Climbed
            case HKQuantityTypeIdentifier.stepCount.rawValue,
                 HKQuantityTypeIdentifier.flightsClimbed.rawValue:
                return WireUnit(hkUnit: .count(), wireSymbol: "count", scale: 1)

            // kcal — Active Energy Burned
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                return WireUnit(hkUnit: .kilocalorie(), wireSymbol: "kcal", scale: 1)

            // m — Distance Walking/Running
            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                return WireUnit(hkUnit: .meter(), wireSymbol: "m", scale: 1)

            // mL/(kg·min) — VO2 Max
            case HKQuantityTypeIdentifier.vo2Max.rawValue:
                let perKgMin = HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())
                let unit = HKUnit.literUnit(with: .milli).unitDivided(by: perKgMin)
                return WireUnit(hkUnit: unit, wireSymbol: "mL/kg*min", scale: 1)

            // dBA — Audio Exposure (env + headphone)
            case HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
                 HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue:
                return WireUnit(hkUnit: .decibelAWeightedSoundPressureLevel(), wireSymbol: "dBA", scale: 1)

            // min — Time in Daylight (iOS 17+, identifier referenziert via raw string,
            // damit der Build auch auf SDKs ohne das Symbol durchgeht).
            case "HKQuantityTypeIdentifierTimeInDaylight":
                return WireUnit(hkUnit: .minute(), wireSymbol: "min", scale: 1)

            // v0.5.2 F2 — walkingSpeed (m/s), walkingStepLength (m),
            // bodyMassIndex (count). walkingSpeed + walkingStepLength are
            // server-persisted since v1.6.0 (W-WALK ungated the
            // `HealthKitServerSupportConfig` set); the wire rows carry the raw
            // HK unit the server's apple-health-mapping expects.
            case HKQuantityTypeIdentifier.walkingSpeed.rawValue:
                let unit = HKUnit.meter().unitDivided(by: HKUnit.second())
                return WireUnit(hkUnit: unit, wireSymbol: "m/s", scale: 1)

            // W-SERVER-SYNC (server v1.5.5) — the server now scales these two
            // gait percentages ×100 server-side, so the wire must carry the
            // RAW HealthKit fraction (0…1), exactly like `walkingSteadiness`.
            // Previously iOS pre-multiplied ×100 which would double-scale
            // against the new server behaviour. `scale: 1` keeps the fraction
            // intact on the wire.
            case HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue:
                return WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 1)

            case HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue:
                return WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 1)

            // W28d — walking steadiness. HK delivers the raw fraction (0…1);
            // the server scales ×100 like the other gait percentages, so the
            // wire carries the fraction intact (`scale: 1`).
            case HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue:
                return WireUnit(hkUnit: .percent(), wireSymbol: "%", scale: 1)

            case HKQuantityTypeIdentifier.walkingStepLength.rawValue:
                return WireUnit(hkUnit: .meter(), wireSymbol: "m", scale: 1)

            case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
                return WireUnit(hkUnit: .count(), wireSymbol: "kg/m^2", scale: 1)

            // W-HKREAD (server v1.10.0) — nine additive HealthKit quantity
            // signals the server's `APPLE_HEALTH_TYPE_MAP` maps end-to-end.
            // Every one ships RAW on the wire (no 0..1 fraction, no client
            // scaling) — the server's `convertToDbUnit` is the identity for
            // these, so `scale: 1` and the natural HK unit match the server's
            // declared `hkUnit` exactly. See `apple-health-mapping.ts` WX-A.

            // bpm — Walking heart-rate average (server `count/min` → bpm).
            case HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue:
                return WireUnit(hkUnit: HKUnit.count().unitDivided(by: .minute()), wireSymbol: "count/min", scale: 1)

            // bpm — Cardio recovery (1-min HR drop; server `count/min` → bpm).
            case HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue:
                return WireUnit(hkUnit: HKUnit.count().unitDivided(by: .minute()), wireSymbol: "count/min", scale: 1)

            // °C — Apple sleeping wrist temperature (absolute reading).
            case HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue:
                return WireUnit(hkUnit: .degreeCelsius(), wireSymbol: "degC", scale: 1)

            // count — Apple sleeping breathing-disturbances (per-night index).
            case HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances.rawValue:
                return WireUnit(hkUnit: .count(), wireSymbol: "count", scale: 1)

            // kg — Lean body mass.
            case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
                return WireUnit(hkUnit: .gramUnit(with: .kilo), wireSymbol: "kg", scale: 1)

            // m — Six-minute-walk-test distance.
            case HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
                return WireUnit(hkUnit: .meter(), wireSymbol: "m", scale: 1)

            // m/s — Stair ascent / descent speed.
            case HKQuantityTypeIdentifier.stairAscentSpeed.rawValue,
                 HKQuantityTypeIdentifier.stairDescentSpeed.rawValue:
                return WireUnit(hkUnit: HKUnit.meter().unitDivided(by: .second()), wireSymbol: "m/s", scale: 1)

            // count — Number of times fallen (cumulative hard-fall tally).
            case HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue:
                return WireUnit(hkUnit: .count(), wireSymbol: "count", scale: 1)

            default:
                return nil
            }
        }

        public struct WireUnit: Sendable, Equatable {
            public let hkUnit: HKUnit
            public let wireSymbol: String
            public let scale: Double

            public init(hkUnit: HKUnit, wireSymbol: String, scale: Double) {
                self.hkUnit = hkUnit
                self.wireSymbol = wireSymbol
                self.scale = scale
            }
        }
    }

#endif
