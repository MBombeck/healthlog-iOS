# Server v1.37.12 — deployment overlay

The file name carries the version because the Xcode test target flattens every
fixture into one bundle directory: a second plain `README.md` next to the
baseline's is a duplicate-output build failure.

This directory is an **overlay**, not a replacement. The immutable baseline in
`../v1.37.3/` stays byte-identical; `provenance.json` pins its SHA-256 digests
and `scripts/verify-server-contract-fixtures.sh` fails if any of them drifts.

## Why the overlay exists

The baseline was captured at tag `v1.37.3`, whose reduced OpenAPI model knows
only `inserted | duplicate | skipped` on `POST /api/measurements/batch`. The
deployed server runs tag `v1.37.12` (revision `d21fe48`) and additionally emits
`updated` and `failed`, and treats a `stats:<type>:<day>` external id as a
mutable upsert. Without this overlay the iOS test suite cannot express the daily
statistic semantics that actually run in production.

## Pinned source

| Field | Value |
|---|---|
| Tag | `v1.37.12` |
| Revision | `d21fe48` |
| Route | `/api/measurements/batch` |
| Entry statuses | `inserted`, `updated`, `duplicate`, `skipped`, `failed` |
| Stat external id | mutable upsert; last matching row in one batch wins |
| Superseded reason | `superseded_in_batch` |

## Contents

`measurement-batch.json` carries one synthetic request (a body-mass sample and a
daily step-count statistic) plus one response document per outcome:
`inserted`, `updated`, `duplicate`, `skipped`, `failed`, and
`superseded-in-batch` (the same stable stat id twice, the earlier row reported
`duplicate` with reason `superseded_in_batch` and the later row `updated`).

## Privacy

Everything here is synthesised. No live response body, host name, account
identifier, credential, token, recorded measurement, dose name, mood label, or
server-local path is checked in. The verifier re-scans this directory for
secret-shaped fields on every run.

## Consumers

- `HealthLogTests/Services/MeasurementBatchResponseContractTests.swift`
- `scripts/verify-server-contract-fixtures.sh` (baseline + overlay)
