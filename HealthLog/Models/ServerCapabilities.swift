import Foundation

/// Decoder for `GET /api/meta/capabilities` — the server's live discovery
/// surface (contract version + the REAL id vocabularies it accepts and emits).
///
/// **CU-01 note: this route had no iOS consumer at all before this file.** A
/// repo-wide grep for `meta/capabilities` / `readScope` / `scopeMintable`
/// returned nothing, so there was no legacy decoder to migrate — this is the
/// first consumption, written straight against the current contract
/// (server v1.34.2).
///
/// **The contract change this file exists for (brief block A4):**
/// - `fhir.readScope` (String) is **gone**, replaced by
///   `fhir.scopeMintable: Bool`.
/// - the share descriptor lost `sections` and `resourceTypes`, and gained four
///   **required** keys: `reportDownload: [String]`, `selectionVersion: Int`,
///   `groups: [String]`, `leaves: [String]`.
///
/// **Naming, verified against the server:** the brief calls the descriptor
/// `capabilities.shareLinks`; the route and the OpenAPI schema both emit
/// **`share`** (`shareLinks` is a different schema — the list payload of
/// `GET /api/share-links`). We decode `share` and accept `shareLinks` as an
/// alias so neither spelling can strand the decode.
///
/// **Decode posture: tolerant everywhere.** Every field is
/// `decodeIfPresent`-with-default. The server marks most of these required, but
/// a discovery surface that throws is worse than useless — it would take down
/// the very call whose job is to tell us what the server can do. An older or
/// newer server that omits or adds a key resolves to an empty list / `false`,
/// and callers branch on emptiness (see ``Share/hasSelectionVocabulary``).
/// Unknown keys are ignored by `JSONDecoder` for free.
public struct ServerCapabilities: Decodable, Sendable, Equatable {
    /// Running API contract version of the server build (mirrors `/api/version`).
    public let apiContractVersion: String
    public let derivedMetricIds: [String]
    public let vitalsBaselineTypes: [String]
    public let layoutTileIds: [String]
    public let metricStatusIds: [String]
    public let ingest: Ingest
    public let fhir: FHIR
    /// Clinician share-link + report-selection descriptor. Wire key `share`
    /// (alias `shareLinks` tolerated — see the type doc).
    public let share: Share

    public init(
        apiContractVersion: String = "",
        derivedMetricIds: [String] = [],
        vitalsBaselineTypes: [String] = [],
        layoutTileIds: [String] = [],
        metricStatusIds: [String] = [],
        ingest: Ingest = Ingest(),
        fhir: FHIR = FHIR(),
        share: Share = Share()
    ) {
        self.apiContractVersion = apiContractVersion
        self.derivedMetricIds = derivedMetricIds
        self.vitalsBaselineTypes = vitalsBaselineTypes
        self.layoutTileIds = layoutTileIds
        self.metricStatusIds = metricStatusIds
        self.ingest = ingest
        self.fhir = fhir
        self.share = share
    }

    private enum CodingKeys: String, CodingKey {
        case apiContractVersion, derivedMetricIds, vitalsBaselineTypes
        case layoutTileIds, metricStatusIds, ingest, fhir, share, shareLinks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiContractVersion = (try? c.decode(String.self, forKey: .apiContractVersion)) ?? ""
        derivedMetricIds = (try? c.decode([String].self, forKey: .derivedMetricIds)) ?? []
        vitalsBaselineTypes = (try? c.decode([String].self, forKey: .vitalsBaselineTypes)) ?? []
        layoutTileIds = (try? c.decode([String].self, forKey: .layoutTileIds)) ?? []
        metricStatusIds = (try? c.decode([String].self, forKey: .metricStatusIds)) ?? []
        ingest = (try? c.decode(Ingest.self, forKey: .ingest)) ?? Ingest()
        fhir = (try? c.decode(FHIR.self, forKey: .fhir)) ?? FHIR()
        share = (try? c.decode(Share.self, forKey: .share))
            ?? (try? c.decode(Share.self, forKey: .shareLinks))
            ?? Share()
    }

    // MARK: - Nested descriptors

    /// Ingest vocabularies the batch / single-write paths accept.
    public struct Ingest: Decodable, Sendable, Equatable {
        public struct QuantityType: Decodable, Sendable, Equatable {
            /// HealthLog `MeasurementType`.
            public let type: String
            /// HealthKit identifier.
            public let hk: String
            /// Canonical DB unit.
            public let unit: String

            public init(type: String, hk: String, unit: String) {
                self.type = type
                self.hk = hk
                self.unit = unit
            }
        }

        public let quantityTypes: [QuantityType]
        /// `MeasurementType`s for device-flagged EVENT-class HealthKit samples.
        public let eventTypes: [String]
        /// Server-owned nightly composite score types.
        public let computedScores: [String]
        /// `MeasurementSource`s a client may attribute on a write.
        public let writeAllowlist: [String]

        public init(
            quantityTypes: [QuantityType] = [],
            eventTypes: [String] = [],
            computedScores: [String] = [],
            writeAllowlist: [String] = []
        ) {
            self.quantityTypes = quantityTypes
            self.eventTypes = eventTypes
            self.computedScores = computedScores
            self.writeAllowlist = writeAllowlist
        }

        private enum CodingKeys: String, CodingKey {
            case quantityTypes, eventTypes, computedScores, writeAllowlist
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quantityTypes = (try? c.decode([Lossy<QuantityType>].self, forKey: .quantityTypes))?
                .compactMap(\.value) ?? []
            eventTypes = (try? c.decode([String].self, forKey: .eventTypes)) ?? []
            computedScores = (try? c.decode([String].self, forKey: .computedScores)) ?? []
            writeAllowlist = (try? c.decode([String].self, forKey: .writeAllowlist)) ?? []
        }
    }

    /// FHIR coding constants + the read-only REST face descriptor.
    public struct FHIR: Decodable, Sendable, Equatable {
        public let atcSystem: String
        public let snomedRoute: String
        public let germanAtcDefaultLocales: [String]
        /// Base path of the read-only FHIR R4 REST face (`/api/fhir`).
        public let restBaseUrl: String
        /// **Replaces the removed `readScope` string.** Whether a narrow Bearer
        /// token for the FHIR face can be obtained at all. The server reports
        /// `false` today: no mint path grants the `fhir:read` scope, so the face
        /// is reachable by the owner's cookie session or a wildcard device token
        /// and by nothing else. Advertising a scope name a client cannot obtain
        /// was the defect this flag replaced — so treat `false` as "do not offer
        /// a scope-minting affordance", not as "FHIR is unavailable".
        public let scopeMintable: Bool
        /// FHIR resource types the REST face serves (read + search).
        public let resourceTypes: [String]
        /// Whole-record operations exposed, e.g. `Patient/$everything`.
        public let operations: [String]
        /// Search parameters honoured uniformly across the search routes.
        public let searchParams: [String]

        public init(
            atcSystem: String = "",
            snomedRoute: String = "",
            germanAtcDefaultLocales: [String] = [],
            restBaseUrl: String = "",
            scopeMintable: Bool = false,
            resourceTypes: [String] = [],
            operations: [String] = [],
            searchParams: [String] = []
        ) {
            self.atcSystem = atcSystem
            self.snomedRoute = snomedRoute
            self.germanAtcDefaultLocales = germanAtcDefaultLocales
            self.restBaseUrl = restBaseUrl
            self.scopeMintable = scopeMintable
            self.resourceTypes = resourceTypes
            self.operations = operations
            self.searchParams = searchParams
        }

        private enum CodingKeys: String, CodingKey {
            case atcSystem, snomedRoute, germanAtcDefaultLocales, restBaseUrl
            case scopeMintable, resourceTypes, operations, searchParams
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            atcSystem = (try? c.decode(String.self, forKey: .atcSystem)) ?? ""
            snomedRoute = (try? c.decode(String.self, forKey: .snomedRoute)) ?? ""
            germanAtcDefaultLocales = (try? c.decode([String].self, forKey: .germanAtcDefaultLocales)) ?? []
            restBaseUrl = (try? c.decode(String.self, forKey: .restBaseUrl)) ?? ""
            scopeMintable = (try? c.decode(Bool.self, forKey: .scopeMintable)) ?? false
            resourceTypes = (try? c.decode([String].self, forKey: .resourceTypes)) ?? []
            operations = (try? c.decode([String].self, forKey: .operations)) ?? []
            searchParams = (try? c.decode([String].self, forKey: .searchParams)) ?? []
        }
    }

    /// Clinician share-link surface descriptor — and, since v1.32.39, the
    /// **authoritative source of the report-selection vocabulary**.
    public struct Share: Decodable, Sendable, Equatable {
        /// Whether clinician share links are served at all.
        public let supported: Bool
        /// Maximum lifetime of a share link in days. There is no never-expiring
        /// share.
        public let maxDays: Int
        /// **New, required.** Machine formats a share link serves as a download
        /// under its token, behind the same unlock the page uses
        /// (`["fhir", "pdf"]` today). Replaced the old `fhirApi: false`, which
        /// described a face that was never built.
        public let reportDownload: [String]
        /// **New, required.** Version of the leaf-selection grammar this server
        /// build speaks. Must equal ``ReportSelection/currentVersion`` for the
        /// selections this app mints to be accepted.
        public let selectionVersion: Int
        /// Selection group ids in presentation order. Kept as a projection so
        /// the existing report picker can consume both legacy string groups and
        /// current object groups without learning a second wire shape.
        public let groups: [String]
        /// Current server-owned group descriptors, including leaf membership and
        /// sensitivity metadata. Legacy string groups are represented with empty
        /// leaves and unknown sensitivity; unknown is treated as sensitive by
        /// ``Group/isSensitive`` so a future semantic cannot widen disclosure.
        public let groupDescriptors: [Group]
        /// **New, required.** Every leaf id a report selection may carry. THE
        /// vocabulary: never mirrored into an app-side constant, always read
        /// from here.
        public let leaves: [String]

        public init(
            supported: Bool = false,
            maxDays: Int = 0,
            reportDownload: [String] = [],
            selectionVersion: Int = 0,
            groups: [String] = [],
            groupDescriptors: [Group]? = nil,
            leaves: [String] = []
        ) {
            self.supported = supported
            self.maxDays = maxDays
            self.reportDownload = reportDownload
            self.selectionVersion = selectionVersion
            let descriptors = groupDescriptors ?? groups.map(Group.init(legacyID:))
            self.groupDescriptors = descriptors
            self.groups = descriptors.map(\.id)
            self.leaves = leaves
        }

        private enum CodingKeys: String, CodingKey {
            case supported, maxDays, reportDownload, selectionVersion, groups, leaves
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            supported = (try? c.decode(Bool.self, forKey: .supported)) ?? false
            maxDays = (try? c.decode(Int.self, forKey: .maxDays)) ?? 0
            reportDownload = (try? c.decode([String].self, forKey: .reportDownload)) ?? []
            selectionVersion = (try? c.decode(Int.self, forKey: .selectionVersion)) ?? 0
            groupDescriptors = (try? c.decode([Lossy<Group>].self, forKey: .groups))?
                .compactMap(\.value) ?? []
            groups = groupDescriptors.map(\.id)
            leaves = (try? c.decode([String].self, forKey: .leaves)) ?? []
        }

        public struct Group: Decodable, Sendable, Equatable {
            public let id: String
            public let leaves: [String]
            /// Exact optional metadata from the server. `nil` means legacy,
            /// omitted, or a future value this build does not understand.
            public let declaredSensitive: Bool?

            public var isSensitive: Bool {
                declaredSensitive != false
            }

            fileprivate init(legacyID: String) {
                self.init(id: legacyID, leaves: [], declaredSensitive: nil)
            }

            private init(id: String, leaves: [String], declaredSensitive: Bool?) {
                self.id = id
                self.leaves = leaves
                self.declaredSensitive = declaredSensitive
            }

            private enum CodingKeys: String, CodingKey {
                case id, leaves, sensitive
            }

            public init(from decoder: Decoder) throws {
                if let legacy = try? decoder.singleValueContainer().decode(String.self) {
                    self.init(legacyID: legacy)
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    id: c.decode(String.self, forKey: .id),
                    leaves: (try? c.decode([String].self, forKey: .leaves)) ?? [],
                    declaredSensitive: try? c.decode(Bool.self, forKey: .sensitive)
                )
            }
        }

        /// The leaf vocabulary as a set, ready for
        /// ``ReportSelection/validate(against:)``.
        public var leafVocabulary: Set<String> {
            Set(leaves)
        }

        /// True iff the server actually served a usable selection vocabulary at
        /// the version this build speaks. A caller that gets `false` must NOT
        /// fall back to a local list — it has no honest selection to offer and
        /// should say so.
        public var hasSelectionVocabulary: Bool {
            !leaves.isEmpty && selectionVersion == ReportSelection.currentVersion
        }
    }
}

/// Element-level lossy decoding for additive discovery arrays. A malformed
/// future element is skipped without discarding valid siblings or the response.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
