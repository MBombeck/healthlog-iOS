# HealthLog server v1.37.3 contract fixtures

These fixtures are a minimal, synthetic snapshot of the server fields consumed
by iOS. They are not captures from a running account. Identifiers use an
explicit `fixture-` prefix, timestamps are fixed test instants, and every health
number is fabricated solely to exercise documented ranges.

## Provenance

- Release: `v1.37.3`
- Tag commit: `1c7efd9b9aa0d83ec3f16fcbc1f2a6c09a31270b`
- Canonical contract: `docs/api/openapi.yaml`
- OpenAPI Git blob: `eda74e0de7f28bc63e61ec9eb96ed88b5dee8629`
- OpenAPI SHA-256:
  `8ad940edbb00013a19d34a6bf947c7f4c398e795b2be6b94e43267b057b9cf30`

Relevant released source blobs:

| Server path | Git blob SHA |
| --- | --- |
| `src/lib/validations/workout.ts` | `95fa195bbe4b70c10244aedf453d8162f322e121` |
| `src/app/api/workouts/batch/route.ts` | `61cfec22c2bf68ccc79205b273127b8b2b9dab04` |
| `src/app/api/insights/ecg/route.ts` | `7cdf4a65fa9e8bf9bceca0bc1d31b6b72f31412d` |
| `src/app/api/meta/capabilities/route.ts` | `64d99ad44f7d1860df844ff2bfd73c81b7e28f36` |
| `src/app/api/auth/me/route.ts` | `1c2a7520d0a30b015a37f1dbdebedb0789b16a37` |
| `src/lib/validations/mood.ts` | `e31fd37c16470bf2fdb8a8a9a935af9f968e190f` |
| `src/app/api/mood-entries/route.ts` | `350095e6025539ef57720697f559040f0dc89f34` |
| `src/app/api/mood-entries/bulk/route.ts` | `00a50e75b8d4f1ca0d6e19115371d75483f6d5d2` |
| `src/lib/mood/context.ts` | `a976428f326eb341628c5f81d9486ad4e32fe6ba` |
| `src/lib/mood/level-a.ts` | `cb1ae02a1b367cec189b880013bb5d93e1a66f8b` |

Fixture checksum added by Plan 02-04:

| Fixture | SHA-256 |
| --- | --- |
| `mood-entry-additive.json` | `05545c8d3c5babef62e3a7e4d8dbb240882c965f3e71046d2f4c30a7187f18ac` |

## Contents

| File | Purpose |
| --- | --- |
| `openapi-consumed.yaml` | Hand-reduced OpenAPI 3.1 subset of only the released route fields iOS consumes in Phase 2. Custom `x-*` keys retain source provenance. |
| `workouts-batch.json` | Exact iOS `{ t, hr }` request plus inserted, enriched, skipped, and future-additive decoder cases. Responses are the inner `data` object because `APIClient` unwraps the server envelope before decoding `WorkoutBatchResponseDTO`. |
| `ecg-ingest.json` | Strict one-record request and all three accepted response statuses. |
| `auth-me-sharing.json` | Additive `accountAccess` shape, including the semantic distinction between `sections: null` and `sections: []`. |
| `capabilities.json` | Current object-valued `share.groups` shape with a server-owned sensitive flag. Arrays are intentionally minimal rather than a production vocabulary capture. |
| `mood-entry-additive.json` | Synthetic mood-list response carrying released `a1...a5` and `context` fields. It proves the existing iOS decoder remains tolerant while this release intentionally adopts no Level-A/context DTO or UI. |

`future-additive` is intentionally outside the pinned server enum. It proves the
client treats additive response data as data instead of failing the whole
response when a later server adds a status or field.

## Refresh procedure

1. Resolve the release tag through the read-only GitHub API and record its
   commit SHA.
2. Fetch `docs/api/openapi.yaml` at that exact tag. Record both its Git blob SHA
   and SHA-256; never use a mutable branch.
3. Rebuild `openapi-consumed.yaml` from only the paths and fields the current iOS
   code calls or decodes. Preserve limits, required fields, nullability, enums,
   and `additionalProperties` behavior.
4. Update fixtures by hand with `fixture-*` identifiers and fabricated values.
   Never paste an authenticated response, a request ID, an email address, a
   token, or a real health sample.
5. Run JSON parsing, the direct secret scan, XcodeGen, and
   `WorkoutV1373ContractTests` and `MoodRepositoryTests` before accepting the refresh.
6. A live health/version probe is optional deployment evidence and takes its
   base URL only from `HEALTHLOG_CONTRACT_BASE_URL`. If it is absent, record
   `operator pending`; never infer a host from source or history.
