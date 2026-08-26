import Foundation

/// v1.28 (GH iOS #45) — the server-authoritative **medication-efficacy**
/// ("Wirkung") payload for `GET /api/medications/{id}/efficacy`.
///
/// **Association-only, server-computed, tolerant-decode.** Every figure — the
/// resolved target(s), the series over time, the start/dose-change/pause
/// markers, the before/after-start comparison, and the cadence-aware adherence
/// lane — is computed on the server (the SAME compliance engine that mints the
/// dose-history ledger). The client NEVER recomputes a delta, a mean, or an
/// adherence rate (PROJECT_GUIDE.md Med-Compliance rule). This surface only *renders*
/// what the server returns and describes a **temporal association** — never a
/// verdict, an efficacy score, a "works / doesn't work" claim, or dose advice.
///
/// **Forward-compatible.** Enum-shaped fields (`reason`, `resolution.tier`,
/// `markers.startSource`, target `kind`, series `status`, before/after
/// `reason`) decode as raw `String?` with typed accessors so an older/newer
/// server literal degrades to an inert value rather than a decode failure. The
/// whole DTO is the *inner* `data` object — `APIClient.send` unwraps the
/// `{ data, error, meta }` envelope. A `404` (route absent on ≤ v1.27 servers)
/// resolves to `nil` at the repository, so the section self-suppresses.
///
/// **`eligible: false`** marks a one-shot / no-target medication whose section
/// is hidden entirely (`reason` = `one_shot` | `no_target`).
public struct MedicationEfficacyDTO: Decodable, Sendable {
    public let medicationId: String
    public let medicationName: String
    public let eligible: Bool
    /// Why the section is hidden when `eligible == false`: `one_shot` | `no_target`.
    public let reason: String?
    public let startsOn: Date?
    public let resolution: Resolution
    public let windowDays: Int
    public let minWeeksPerSide: Int
    public let markers: Markers
    public let targets: [Target]
    public let adherence: [AdherencePoint]
    public let overrideOptions: OverrideOptions

    /// How the target was resolved. `tier`: `override` (user pin) | `atc`
    /// (ATC-class default) | `name` (name heuristic) | `none`.
    public struct Resolution: Decodable, Sendable {
        public let tier: String
        public let cls: String?

        /// True when the user has pinned an explicit target (the "reset to
        /// default" affordance is offered only then).
        public var isOverride: Bool {
            tier == "override"
        }
    }

    /// The timeline markers overlaid on every target chart.
    public struct Markers: Decodable, Sendable {
        /// The pivot the before/after comparison hinges on. `nil` → no start
        /// resolvable (the honest no-start state).
        public let start: Date?
        /// `startsOn` (explicit start date) | `firstReading` (fallback pivot).
        public let startSource: String?
        public let doseChanges: [DoseChange]
        public let pauses: [Pause]

        public var startFromFirstReading: Bool {
            startSource == "firstReading"
        }

        public struct DoseChange: Decodable, Sendable, Identifiable {
            public let at: Date
            public let label: String
            public var id: Date {
                at
            }
        }

        /// A pause in taking the medication. `to == nil` → still paused (runs
        /// to the latest datum on the chart).
        public struct Pause: Decodable, Sendable, Identifiable {
            public let from: Date
            public let to: Date?
            public var id: Date {
                from
            }
        }
    }

    /// One outcome the medication is tracked against — a metric OR a lab.
    public struct Target: Decodable, Sendable, Identifiable {
        /// `metric` | `lab`.
        public let kind: String
        /// The metric measurement-type key or the biomarker id.
        public let key: String
        public let label: String
        public let unit: String?
        public let primary: Bool
        /// Population "typical range" — faint context, NEVER a goal line.
        public let referenceBand: ReferenceBand?
        public let series: [Point]
        public let beforeAfter: BeforeAfter
        public let levelShift: LevelShift?

        public var id: String {
            "\(kind):\(key)"
        }

        public var isLab: Bool {
            kind == "lab"
        }

        public struct ReferenceBand: Decodable, Sendable {
            public let low: Double
            public let high: Double
        }

        public struct Point: Decodable, Sendable, Identifiable {
            public let t: Date
            public let value: Double
            /// `in-range` | `below` | `above` | `unknown` — context only, not a
            /// verdict; the chart paints the series in one monochrome tint.
            public let status: String?
            public var id: Date {
                t
            }
        }

        /// The before/after-start comparison. `present == false` carries an
        /// honest `reason` (`insufficient_before` | `insufficient_after` |
        /// `no_start` | `no_data`) instead of a fabricated delta.
        public struct BeforeAfter: Decodable, Sendable {
            public let present: Bool
            public let reason: String?
            public let before: Side?
            public let after: Side?
            public let delta: Delta?

            public struct Side: Decodable, Sendable {
                public let mean: Double
                public let count: Int
                public let from: Date
                public let to: Date
            }

            public struct Delta: Decodable, Sendable {
                public let mean: Double
                public let pct: Double?
            }

            /// True only when every piece needed to render the summary is here.
            public var isRenderable: Bool {
                present && before != nil && after != nil && delta != nil
            }
        }

        /// A conservative server-detected level shift in the series. Surfaced
        /// only when `present && nearStart` — a neutral "a shift was detected
        /// around {date}" note, explicitly not attributed to the medication.
        public struct LevelShift: Decodable, Sendable {
            public let present: Bool
            public let at: Date?
            public let nearStart: Bool?

            public var isNearStart: Bool {
                present && (nearStart ?? false)
            }
        }
    }

    /// One day of the cadence-aware adherence lane. `rate` is server-graded
    /// (0…100); `taken`/`missed` are server counts. Rendered verbatim — the
    /// client never re-derives a compliance percentage from these.
    public struct AdherencePoint: Decodable, Sendable, Identifiable {
        public let date: Date
        public let rate: Double
        public let taken: Int
        public let missed: Int
        public var id: Date {
            date
        }
    }

    /// The retarget picker's options — the metrics + biomarkers the user can
    /// pin this medication against.
    public struct OverrideOptions: Decodable, Sendable {
        public let metrics: [MetricOption]
        public let biomarkers: [BiomarkerOption]

        public var isEmpty: Bool {
            metrics.isEmpty && biomarkers.isEmpty
        }

        public struct MetricOption: Decodable, Sendable, Identifiable {
            /// The `measurementType` enum value (e.g. `WEIGHT`).
            public let key: String
            public let label: String
            public var id: String {
                key
            }
        }

        public struct BiomarkerOption: Decodable, Sendable, Identifiable {
            public let id: String
            public let label: String
            public let unit: String
        }
    }
}

// MARK: - Efficacy-target write (PUT /efficacy/target)

/// The user's explicit efficacy-target pin — the ONLY thing the view persists
/// (everything else is derived server-side each read). Exactly one of
/// `.metric` / `.lab`, or `.clear` to revert to the derived (ATC/name) target.
public enum EfficacyTargetSelection: Sendable, Equatable {
    /// Pin a metric by its `measurementType` enum value.
    case metric(String)
    /// Pin a lab by its biomarker id.
    case lab(String)
    /// Clear the pin — revert to the server-derived default.
    case clear
}

/// Wire body for `PUT /api/medications/{id}/efficacy/target`. Pin exactly one
/// of `measurementType` / `biomarkerId`, or `clear: true`.
public struct EfficacyTargetBody: Encodable, Sendable {
    public let clear: Bool?
    public let measurementType: String?
    public let biomarkerId: String?
    public let primary: Bool?

    public init(selection: EfficacyTargetSelection, primary: Bool? = nil) {
        switch selection {
        case let .metric(type):
            clear = nil
            measurementType = type
            biomarkerId = nil
            self.primary = primary
        case let .lab(id):
            clear = nil
            measurementType = nil
            biomarkerId = id
            self.primary = primary
        case .clear:
            clear = true
            measurementType = nil
            biomarkerId = nil
            self.primary = nil
        }
    }
}

/// Decoded result of the target PUT (`data: { ok, cleared }`). Tolerant —
/// both flags optional so an older/newer server shape never fails the decode.
public struct EfficacyTargetResult: Decodable, Sendable {
    public let ok: Bool?
    public let cleared: Bool?
}
