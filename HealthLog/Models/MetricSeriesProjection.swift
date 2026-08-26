import Foundation

/// Kind-aware projection from a slice of `Measurement` rows into the
/// `[Double]` series the dashboard sparkline + chart-detail mini-chart consume.
///
/// **Why this exists (v0.5.4.3 HP-2, fourth attempt at BP+Pulse sparkline).**
/// The previous three attempts (V052-A1 B2, V053-D23 D2, V054-BF234 universal
/// hydration) each ran `MeasurementValue.primaryComponent` over the in-range
/// samples. That is correct in the happy path, but the operator's real-device
/// walkthrough kept reporting the same bug — BP + Puls tiles render value
/// without chart — and the unit tests still passed against the synthetic
/// fixtures every time.
///
/// Forensic trail, root causes the projection now neutralises:
///
/// 1. **BP pair-merge partial failure.** The server stores BP as two rows
///    (`BLOOD_PRESSURE_SYS` + `BLOOD_PRESSURE_DIA`) per reading.
///    `MeasurementAggregator.mergeBloodPressure` pairs them by **exact** Date
///    equality of `measuredAt`. When the server's two paired rows have
///    millisecond-level identical timestamps the merge succeeds — but a HK-
///    synced reading or a manual reading whose two rows pass through Postgres
///    + Prisma + JSON-ISO8601 + Swift `JSONDecoder` round-trip can land with
///    differing fractional-second precision. The unpaired half passes through
///    `MeasurementWireDTO.toDomain` as `.bloodPressure(systolic: 0, diastolic: d)`
///    (or `(s, 0)` when the diastolic side was missing). `primaryComponent` on
///    such a row returns `0`, which polluted the prior sparkline arrays as
///    `[124, 0, 122, 0, 126, 0]`. With `HLSparkline.yDomain` deriving
///    `min=0, max=126`, the actual readings squeeze into a 4 pt sliver at the
///    very top of the 36 pt tile — visually indistinguishable from "no chart".
///
/// 2. **Pulse vs heartRate ambiguity.** `MetricKind.pulse` is wire-key `pulse`
///    on `/api/measurements/series` and `PULSE` on `/api/measurements`. There
///    is no mapping error today, but explicitly routing pulse through this
///    helper documents the contract + locks regression should the server
///    refactor pulse into a HK-style time-binned table later.
///
/// 3. **Duplicate timestamps from cache+network race.** The SWR coordinator
///    can briefly surface the same reading twice during a stale-then-fresh
///    revalidation. Dedup-by-recordedAt collapses the duplicate before the
///    chart sees it, preventing a one-frame spike to a doubled point.
///
/// **Contract:**
/// - `systolicOnly(_:)` drops every `Measurement` whose value resolves to
///   systolic == 0 (the unpaired-DIA artifact), then maps each survivor to its
///   systolic component sorted ascending by `recordedAt`.
/// - `heartRate(_:)` filters non-positive values (defensive — pulse readings
///   are always > 0; a zero would indicate a parsing fault) and sorts asc.
/// - `default(_:)` is the legacy `primaryComponent` path for every other kind
///   that doesn't need a kind-aware projection.
/// - All three dedup same-`recordedAt` rows (last-wins) to neutralise the SWR
///   stale+fresh race.
///
/// **Why `nonisolated public enum` with `static` funcs:** pure transformations,
/// no state, no actor isolation needed. Callable from any context — notably
/// `HLDashboardTile.sparklineValues` (`@MainActor` body) AND
/// `DashboardStoreSparklineHydrationTests` (synchronous test fixture).
public enum MetricSeriesProjection {
    /// Project a slice of BP `Measurement` rows into a systolic-only
    /// `[Double]`. Drops unpaired-DIA artifacts whose systolic component is
    /// zero (see helper doc — these are the silent kill-switch behind the
    /// "BP tile renders no chart" operator report since v0.5.1).
    public static func systolicOnly(_ samples: [Measurement]) -> [Double] {
        dedupAndSort(samples)
            .compactMap { measurement -> Double? in
                switch measurement.value {
                case let .bloodPressure(systolic, _):
                    // Filter the unpaired-DIA artifact: a measurement that
                    // arrived without its systolic peer is encoded with
                    // `systolic == 0` by `MeasurementWireDTO.toDomain`. The
                    // peer-merge in `MeasurementAggregator` should have
                    // collapsed it into a proper pair — when it didn't, the
                    // row carries zero in the systolic slot. Drop it so the
                    // chart's y-domain isn't crushed.
                    return systolic > 0 ? systolic : nil
                case let .scalar(value):
                    // Defensive: a BP row encoded as scalar shouldn't occur,
                    // but if it does treat the scalar as a systolic reading.
                    return value > 0 ? value : nil
                }
            }
    }

    /// Project a slice of pulse `Measurement` rows into the bpm `[Double]`
    /// series. Today this is functionally identical to the `primaryComponent`
    /// fallback, but the explicit kind-aware entry point documents the
    /// pulse-specific contract and locks the projection against future
    /// `MetricKind.pulse` refactors (e.g. server moving heart-rate into a
    /// time-binned table).
    public static func heartRate(_ samples: [Measurement]) -> [Double] {
        dedupAndSort(samples)
            .compactMap { measurement -> Double? in
                let bpm = measurement.value.primaryComponent
                // Defensive non-positive filter — a zero pulse reading would
                // indicate a parsing fault rather than legitimate data.
                return bpm > 0 ? bpm : nil
            }
    }

    /// Default `primaryComponent` projection for every kind that doesn't need
    /// a kind-aware override. Sorted asc by `recordedAt` and deduped on
    /// timestamp to match the BP / pulse paths.
    public static func `default`(_ samples: [Measurement]) -> [Double] {
        dedupAndSort(samples).map(\.value.primaryComponent)
    }

    /// Single dispatch entry point — picks the right projection from the kind.
    /// Saves call sites from a `switch kind {}` they would otherwise need to
    /// keep in lockstep with new kinds.
    public static func project(_ samples: [Measurement], kind: MetricKind) -> [Double] {
        switch kind {
        case .bloodPressure: systolicOnly(samples)
        case .pulse, .restingHeartRate: heartRate(samples)
        default: Self.default(samples)
        }
    }

    /// De-duplicate on `recordedAt` (last-wins) and sort ascending. Pure
    /// helper — exposed `internal` so test suites can pin the dedup contract
    /// without round-tripping the projection wrappers.
    static func dedupAndSort(_ samples: [Measurement]) -> [Measurement] {
        var byTimestamp: [Date: Measurement] = [:]
        for sample in samples {
            byTimestamp[sample.recordedAt] = sample
        }
        return byTimestamp.values.sorted { $0.recordedAt < $1.recordedAt }
    }
}
