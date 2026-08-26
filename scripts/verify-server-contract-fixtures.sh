#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$REPO_ROOT/HealthLogTests/Fixtures/Server"
FIXTURE_DIR="$SERVER_DIR/v1.37.3"
OVERLAY_DIR="$SERVER_DIR/v1.37.12"

verify_contract() {
  local fixture_dir="$1"

  ruby -e '
    require "yaml"
    document = Psych.parse_file(ARGV.fetch(0))
    abort "ERROR: consumed OpenAPI YAML must contain a document" if document.nil?
  ' "$fixture_dir/openapi-consumed.yaml"

  python3 - "$REPO_ROOT" "$fixture_dir" <<'PY'
import json
import hashlib
import re
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
fixture_dir = Path(sys.argv[2])


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


required_files = {
    "fixture README": fixture_dir / "README.md",
    "consumed OpenAPI": fixture_dir / "openapi-consumed.yaml",
    "workout fixture": fixture_dir / "workouts-batch.json",
    "ECG fixture": fixture_dir / "ecg-ingest.json",
    "sharing fixture": fixture_dir / "auth-me-sharing.json",
    "capabilities fixture": fixture_dir / "capabilities.json",
    "additive mood fixture": fixture_dir / "mood-entry-additive.json",
    "route matrix": repo_root / ".planning/active/apple-review-reliability/ROUTE-MATRIX.md",
    "deployed contract evidence": repo_root / ".planning/active/apple-review-reliability/DEPLOYED-SERVER-CONTRACT.md",
    "canonical route source": repo_root / "HealthLog/Services/HealthIngestRoute.swift",
    "workouts repository": repo_root / "HealthLog/Repositories/WorkoutsRepository.swift",
    "ECG repository": repo_root / "HealthLog/Repositories/EcgRepository.swift",
}
for label, path in required_files.items():
    require(path.is_file(), f"missing required {label}: {path}")

json_documents: dict[str, object] = {}
for name in ("workouts-batch.json", "ecg-ingest.json", "auth-me-sharing.json", "capabilities.json", "mood-entry-additive.json"):
    path = fixture_dir / name
    try:
        with path.open(encoding="utf-8") as handle:
            json_documents[name] = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid JSON in {path}: {error}")

readme = required_files["fixture README"].read_text(encoding="utf-8")
openapi = required_files["consumed OpenAPI"].read_text(encoding="utf-8")
evidence = required_files["deployed contract evidence"].read_text(encoding="utf-8")
route_source = required_files["canonical route source"].read_text(encoding="utf-8")
workouts_repository = required_files["workouts repository"].read_text(encoding="utf-8")
ecg_repository = required_files["ECG repository"].read_text(encoding="utf-8")
route_matrix = required_files["route matrix"].read_text(encoding="utf-8")

secret_pattern = re.compile(
    r'(BEGIN\s+.*PRIVATE KEY|authorization["\'\s]*:\s*["\']?\s*bearer|["\']?password["\']?\s*:|["\']?secret["\']?\s*:)',
    re.IGNORECASE,
)
for path in fixture_dir.rglob("*"):
    if not path.is_file():
        continue
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"fixture is not readable UTF-8: {path.name}: {error}")
    require(secret_pattern.search(contents) is None, "fixture privacy scan found a forbidden secret-shaped field")

provenance = {
    "tag": "v1.37.3",
    "commit": "1c7efd9b9aa0d83ec3f16fcbc1f2a6c09a31270b",
    "openapi_blob": "eda74e0de7f28bc63e61ec9eb96ed88b5dee8629",
    "openapi_sha256": "8ad940edbb00013a19d34a6bf947c7f4c398e795b2be6b94e43267b057b9cf30",
}
for label, value in provenance.items():
    require(value in readme, f"fixture README is missing pinned {label} {value}")
    require(value in openapi, f"consumed OpenAPI is missing pinned {label} {value}")
    require(value in evidence, f"deployed evidence is missing pinned {label} {value}")

source_blobs = {
    "src/lib/validations/workout.ts": "95fa195bbe4b70c10244aedf453d8162f322e121",
    "src/app/api/workouts/batch/route.ts": "61cfec22c2bf68ccc79205b273127b8b2b9dab04",
    "src/app/api/insights/ecg/route.ts": "7cdf4a65fa9e8bf9bceca0bc1d31b6b72f31412d",
    "src/app/api/meta/capabilities/route.ts": "64d99ad44f7d1860df844ff2bfd73c81b7e28f36",
    "src/app/api/auth/me/route.ts": "1c2a7520d0a30b015a37f1dbdebedb0789b16a37",
    "src/lib/validations/mood.ts": "e31fd37c16470bf2fdb8a8a9a935af9f968e190f",
    "src/app/api/mood-entries/route.ts": "350095e6025539ef57720697f559040f0dc89f34",
    "src/app/api/mood-entries/bulk/route.ts": "00a50e75b8d4f1ca0d6e19115371d75483f6d5d2",
    "src/lib/mood/context.ts": "a976428f326eb341628c5f81d9486ad4e32fe6ba",
    "src/lib/mood/level-a.ts": "cb1ae02a1b367cec189b880013bb5d93e1a66f8b",
}
for source_path, blob_sha in source_blobs.items():
    require(source_path in readme, f"fixture README is missing source path {source_path}")
    require(blob_sha in readme, f"fixture README is missing blob SHA for {source_path}")

schema_paths = ("/api/workouts/batch", "/api/insights/ecg", "/api/meta/capabilities", "/api/auth/me", "/api/mood-entries")
for path in schema_paths:
    require(re.search(rf"^  {re.escape(path)}:$", openapi, re.MULTILINE) is not None, f"schema path missing: {path}")

route_lines = (
    'static let workoutsBatch = "/api/workouts/batch"',
    'static let ecgIngest = "/api/insights/ecg"',
    "static let ecgList = ecgIngest",
    '"\\(ecgList)/\\(id)"',
)
for line in route_lines:
    require(line in route_source, f"canonical route source is missing: {line}")
require("HealthIngestRoute.workoutsBatch" in workouts_repository, "workouts repository bypasses canonical batch route")
require('"/api/workouts/batch"' not in workouts_repository, "workouts repository duplicates the batch route literal")
for member in ("ecgList", "ecgDetail(id: id)", "ecgIngest"):
    require(f"HealthIngestRoute.{member}" in ecg_repository, f"ECG repository bypasses canonical {member} route")
require('"/api/insights/ecg' not in ecg_repository, "ECG repository duplicates the ECG route literal")

workout = json_documents["workouts-batch.json"]
require(isinstance(workout, dict), "workout fixture root must be an object")
request = workout.get("request")
responses = workout.get("responses")
require(isinstance(request, dict), "workout fixture request must be an object")
require(isinstance(responses, dict), "workout fixture responses must be an object")
workouts = request.get("workouts")
require(isinstance(workouts, list) and workouts, "workout fixture needs at least one request workout")
required_workout_fields = {"sportType", "startedAt", "endedAt", "source", "externalId", "samples"}
require(required_workout_fields <= set(workouts[0]), "workout request is missing consumed fields")
samples = workouts[0].get("samples")
require(isinstance(samples, list) and samples, "workout fixture needs at least one sample")
require(all(set(sample) == {"t", "hr"} for sample in samples), "iOS workout samples must contain exactly t and hr")

required_workout_cases = {
    "inserted": "inserted",
    "enriched": "enriched",
    "skipped": "skipped",
    "future-additive": "reconciled",
}
for case, expected_status in required_workout_cases.items():
    response = responses.get(case)
    require(isinstance(response, dict), f"workout fixture is missing required response case: {case}")
    require({"processed", "inserted", "duplicates", "skipped", "entries"} <= set(response), f"{case} response is missing required fields")
    entries = response.get("entries")
    require(isinstance(entries, list) and entries, f"{case} response needs an entry")
    require(entries[0].get("status") == expected_status, f"{case} response lost status {expected_status}")

for status in ("inserted", "duplicate", "enriched", "skipped"):
    require(re.search(rf"enum: \[[^\]]*\b{status}\b[^\]]*\]", openapi) is not None, f"OpenAPI lost workout status {status}")
for field in ("processed", "inserted", "duplicates", "skipped", "entries"):
    require(re.search(rf"required: \[[^\]]*\b{field}\b[^\]]*\]", openapi) is not None, f"OpenAPI lost workout response field {field}")

ecg = json_documents["ecg-ingest.json"]
require(isinstance(ecg, dict), "ECG fixture root must be an object")
ecg_request = ecg.get("request")
ecg_responses = ecg.get("responses")
required_ecg_fields = {"externalRecordingId", "recordedAt", "samplingFrequency", "samples", "source"}
require(isinstance(ecg_request, dict) and required_ecg_fields <= set(ecg_request), "ECG request is missing required fields")
require(isinstance(ecg_responses, dict), "ECG responses must be an object")
for status in ("inserted", "updated", "duplicate"):
    response = ecg_responses.get(status)
    require(isinstance(response, dict), f"ECG fixture is missing response status {status}")
    require(response.get("data", {}).get("status") == status, f"ECG response case {status} has the wrong status")

mood_path = required_files["additive mood fixture"]
mood_checksum = hashlib.sha256(mood_path.read_bytes()).hexdigest()
expected_mood_checksum = "05545c8d3c5babef62e3a7e4d8dbb240882c965f3e71046d2f4c30a7187f18ac"
require(mood_checksum == expected_mood_checksum, "additive mood fixture checksum drifted")
require(expected_mood_checksum in readme, "fixture README is missing the additive mood checksum")
mood = json_documents["mood-entry-additive.json"]
require(isinstance(mood, dict), "additive mood fixture root must be an object")
mood_response = mood.get("response")
require(isinstance(mood_response, dict), "additive mood fixture response must be an object")
mood_entries = mood_response.get("entries")
require(isinstance(mood_entries, list) and len(mood_entries) == 1, "additive mood fixture needs exactly one entry")
mood_entry = mood_entries[0]
require(isinstance(mood_entry, dict), "additive mood fixture entry must be an object")
for field in ("a1", "a2", "a3", "a4", "a5", "context"):
    require(field in mood_entry, f"additive mood fixture is missing {field}")
    require(re.search(rf"^        {field}:|^        {field}: \{{", openapi, re.MULTILINE) is not None, f"consumed OpenAPI is missing mood field {field}")
require(isinstance(mood_entry.get("context"), dict), "additive mood fixture context must be an object")
require("x-ios-tolerates-additive: [a1, a2, a3, a4, a5, context]" in openapi, "consumed OpenAPI lost the intentional mood tolerance marker")

for issue in (74, 78, 84, 85, 86, 87, 88, 89):
    require(f"[#{issue}]" in route_matrix, f"route matrix is missing issue #{issue}")
matrix_routes = (
    "/api/insights/ecg",
    "/api/meta/capabilities",
    "/api/auth/me",
    "/api/mood-entries/bulk",
    "/api/workouts/batch",
    "/api/practitioners",
    "/api/encounters",
    "/api/mood/prognosis",
    "/api/vaccinations",
)
for path in matrix_routes:
    require(path in route_matrix, f"route matrix is missing route family {path}")

print("Server contract fixture verification passed.")
PY
}

# Phase 07 Wave 0 — the deployed v1.37.12 measurement-batch overlay. The overlay
# never replaces the immutable v1.37.3 baseline: it pins the baseline's digests
# and adds only the deployed result vocabulary the baseline cannot express.
verify_overlay() {
  local baseline_dir="$1"
  local overlay_dir="$2"

  python3 - "$baseline_dir" "$overlay_dir" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

baseline_dir = Path(sys.argv[1])
overlay_dir = Path(sys.argv[2])


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


required_files = {
    # The file name is version-qualified on purpose: the Xcode test target
    # flattens every fixture into one bundle directory, so a second `README.md`
    # would be a duplicate-output build failure.
    "overlay README": overlay_dir / "README-v1.37.12.md",
    "overlay provenance": overlay_dir / "provenance.json",
    "overlay measurement batch": overlay_dir / "measurement-batch.json",
}
for label, path in required_files.items():
    require(path.is_file(), f"missing required {label}: {path}")

try:
    provenance = json.loads(required_files["overlay provenance"].read_text(encoding="utf-8"))
    fixture = json.loads(required_files["overlay measurement batch"].read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    fail(f"overlay JSON is unreadable: {error}")

readme = required_files["overlay README"].read_text(encoding="utf-8")

secret_pattern = re.compile(
    r'(BEGIN\s+.*PRIVATE KEY|authorization["\'\s]*:\s*["\']?\s*bearer|["\']?password["\']?\s*:|["\']?secret["\']?\s*:'
    r'|["\']?token["\']?\s*:\s*["\'][^"\']+["\'])',
    re.IGNORECASE,
)
for path in overlay_dir.rglob("*"):
    if not path.is_file():
        continue
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"overlay fixture is not readable UTF-8: {path.name}: {error}")
    require(secret_pattern.search(contents) is None, "overlay privacy scan found a forbidden secret-shaped field")
    require(
        re.search(r"https?://(?!\S*example)", contents) is None,
        "overlay must not carry a live server URL",
    )

require(provenance.get("tag") == "v1.37.12", "overlay provenance must pin server tag v1.37.12")
require(provenance.get("revision") == "d21fe48", "overlay provenance must pin server revision d21fe48")
require(provenance.get("extends") == "v1.37.3", "overlay must extend the v1.37.3 baseline")
require(provenance.get("supersedes") is None, "overlay must not supersede the baseline")
require("v1.37.12" in readme and "d21fe48" in readme, "overlay README must pin tag and revision")

expected_statuses = ["inserted", "updated", "duplicate", "skipped", "failed"]
require(
    provenance.get("entryStatusVocabulary") == expected_statuses,
    "overlay provenance must pin the exact deployed status vocabulary",
)
require(
    provenance.get("supersededInBatchReason") == "superseded_in_batch",
    "overlay provenance must pin the superseded_in_batch reason",
)

pinned = provenance.get("baselineMustRemainUnchanged")
require(isinstance(pinned, dict) and pinned, "overlay provenance must pin every baseline digest")
baseline_files = sorted(path.name for path in baseline_dir.iterdir() if path.is_file())
require(sorted(pinned) == baseline_files, "pinned baseline digests do not cover the baseline exactly")
for name, digest in pinned.items():
    path = baseline_dir / name
    require(path.is_file(), f"pinned baseline file is missing: {name}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    require(actual == digest, f"immutable baseline byte drift detected in {name}")

request = fixture.get("request")
responses = fixture.get("responses")
require(isinstance(request, dict), "overlay request must be an object")
require(isinstance(responses, dict), "overlay responses must be an object")
entries = request.get("entries")
require(isinstance(entries, list) and len(entries) == 2, "overlay request needs exactly two synthetic entries")
required_entry_fields = {"hkIdentifier", "value", "unit", "startDate", "endDate", "externalId"}
for entry in entries:
    require(isinstance(entry, dict), "overlay request entry must be an object")
    require(required_entry_fields <= set(entry), "overlay request entry is missing consumed fields")
require(
    any(str(entry.get("externalId", "")).startswith("stats:") for entry in entries),
    "overlay request must carry a stable stats: external id",
)

expected_cases = {
    "inserted": "inserted",
    "updated": "updated",
    "duplicate": "duplicate",
    "skipped": "skipped",
    "failed": "failed",
}
require(
    set(responses) == set(expected_cases) | {"superseded-in-batch"},
    "overlay responses must be exactly the deployed vocabulary plus superseded-in-batch",
)
for case, status in expected_cases.items():
    response = responses.get(case)
    require(isinstance(response, dict), f"overlay is missing response case: {case}")
    require(
        {"processed", "inserted", "duplicates", "skipped", "entries"} <= set(response),
        f"overlay {case} response is missing required counters",
    )
    rows = response.get("entries")
    require(isinstance(rows, list) and len(rows) == 1, f"overlay {case} response needs exactly one entry row")
    require(rows[0].get("index") == 0, f"overlay {case} response row must be index 0")
    require(rows[0].get("status") == status, f"overlay {case} response lost status {status}")

superseded = responses.get("superseded-in-batch")
require(isinstance(superseded, dict), "overlay is missing the superseded-in-batch case")
rows = superseded.get("entries")
require(isinstance(rows, list) and len(rows) == 2, "superseded-in-batch needs both stat rows")
require(
    rows[0].get("status") == "duplicate" and rows[0].get("reason") == "superseded_in_batch",
    "superseded-in-batch must report the earlier row as a superseded duplicate",
)
require(rows[1].get("status") == "updated", "superseded-in-batch must report the later row as updated")
require(
    [row.get("index") for row in rows] == [0, 1],
    "superseded-in-batch must cover every posted index exactly once",
)

print("Server contract overlay verification passed (v1.37.12 over v1.37.3).")
PY
}

run_self_test() {
  verify_contract "$FIXTURE_DIR"
  verify_overlay "$FIXTURE_DIR" "$OVERLAY_DIR"

  local overlay_root
  overlay_root="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-overlay-self-test.XXXXXX")"
  for mutation in missing-provenance baseline-drift unknown-status secret-shaped; do
    mkdir -p "$overlay_root/$mutation"
    cp -R "$FIXTURE_DIR" "$overlay_root/$mutation/v1.37.3"
    cp -R "$OVERLAY_DIR" "$overlay_root/$mutation/v1.37.12"
  done

  rm -f -- "$overlay_root/missing-provenance/v1.37.12/provenance.json"

  python3 - "$overlay_root/baseline-drift/v1.37.3/capabilities.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixture = json.loads(path.read_text(encoding="utf-8"))
fixture["overlaySelfTestMarker"] = True
path.write_text(json.dumps(fixture), encoding="utf-8")
PY

  python3 - "$overlay_root/unknown-status/v1.37.12/measurement-batch.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixture = json.loads(path.read_text(encoding="utf-8"))
fixture["responses"]["updated"]["entries"][0]["status"] = "reconciled"
path.write_text(json.dumps(fixture), encoding="utf-8")
PY

  python3 - "$overlay_root/secret-shaped/v1.37.12/measurement-batch.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixture = json.loads(path.read_text(encoding="utf-8"))
fixture["secret"] = "fixture-only"
path.write_text(json.dumps(fixture), encoding="utf-8")
PY

  for mutation in missing-provenance baseline-drift unknown-status secret-shaped; do
    if verify_overlay "$overlay_root/$mutation/v1.37.3" "$overlay_root/$mutation/v1.37.12" >/dev/null 2>&1; then
      rm -rf -- "$overlay_root"
      echo "ERROR: overlay self-test mutation was accepted: $mutation" >&2
      exit 1
    fi
  done
  rm -rf -- "$overlay_root"
  echo "Overlay self-test passed: missing provenance, baseline drift, unknown status, and secret-shaped data were rejected."

  local temporary_root
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/healthlog-contract-self-test.XXXXXX")"
  cp -R "$FIXTURE_DIR" "$temporary_root/missing-status"
  cp -R "$FIXTURE_DIR" "$temporary_root/malformed-yaml"
  cp -R "$FIXTURE_DIR" "$temporary_root/secret-shaped-field"

  python3 - "$temporary_root/missing-status/workouts-batch.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixture = json.loads(path.read_text(encoding="utf-8"))
fixture["responses"].pop("enriched", None)
path.write_text(json.dumps(fixture), encoding="utf-8")
PY

  if verify_contract "$temporary_root/missing-status" >/dev/null 2>&1; then
    rm -rf -- "$temporary_root"
    echo "ERROR: self-test mutation was accepted" >&2
    exit 1
  fi

  python3 - "$temporary_root/malformed-yaml/openapi-consumed.yaml" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_text("openapi: [\n", encoding="utf-8")
PY

  if verify_contract "$temporary_root/malformed-yaml" >/dev/null 2>&1; then
    rm -rf -- "$temporary_root"
    echo "ERROR: malformed YAML self-test mutation was accepted" >&2
    exit 1
  fi

  python3 - "$temporary_root/secret-shaped-field/capabilities.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
fixture = json.loads(path.read_text(encoding="utf-8"))
fixture["secret"] = "fixture-only"
path.write_text(json.dumps(fixture), encoding="utf-8")
PY

  if verify_contract "$temporary_root/secret-shaped-field" >/dev/null 2>&1; then
    rm -rf -- "$temporary_root"
    echo "ERROR: secret-pattern self-test mutation was accepted" >&2
    exit 1
  fi
  rm -rf -- "$temporary_root"
  echo "Server contract fixture self-test passed: missing status, malformed YAML, and secret-shaped data were rejected."
}

case "${1:-}" in
  "")
    verify_contract "$FIXTURE_DIR"
    verify_overlay "$FIXTURE_DIR" "$OVERLAY_DIR"
    ;;
  --self-test)
    run_self_test
    ;;
  *)
    echo "Usage: $0 [--self-test]" >&2
    exit 64
    ;;
esac
