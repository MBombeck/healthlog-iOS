#!/usr/bin/env bash
# Extract SHA-256 SPKI hashes for every certificate in a host's TLS chain.
# Usage: scripts/extract-spki.sh <hostname> [port]
#   scripts/extract-spki.sh health.example.com
#   scripts/extract-spki.sh health.example.com 443
#
# Output (per certificate, in chain order leaf -> intermediate(s) -> root):
#   [N] subject=...
#       issuer=...
#       notBefore=...  notAfter=...
#       SPKI(SHA-256, b64): <hash>
#
# The base64 hash is ready to paste into the `HLPinnedSPKIHashes` array
# in `Config/local.yml` — the local, NOT checked-in operator overlay that
# xcodegen renders into Info.plist (template: `Config/local.example.yml`,
# activated via `HL_LOCAL_CONFIG=1 xcodegen`). A build with no overlay ships
# with no pinning at all, which is a valid self-hoster state. But a build that
# DECLARES pinning must carry a host list AND
# >= CertificatePinner.minimumProductionPinCount (= 2) well-formed entries,
# or the Release build trips the AppContainer precondition.
#
# Rotation playbook: docs/security.md "Pin rotation policy".
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <hostname> [port]" >&2
    exit 1
fi

HOST="$1"
PORT="${2:-443}"

TMPDIR="$(mktemp -d -t spki-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

CHAIN_PEM="$TMPDIR/chain.pem"

# Pull the full presented chain (-showcerts) and strip session preamble so we
# are left with concatenated PEM blocks.
openssl s_client \
    -servername "$HOST" \
    -connect "${HOST}:${PORT}" \
    -showcerts </dev/null 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  > "$CHAIN_PEM"

if ! grep -q "BEGIN CERTIFICATE" "$CHAIN_PEM"; then
    echo "ERROR: no certificates returned by ${HOST}:${PORT}" >&2
    exit 2
fi

# Split the concatenated PEM into per-cert files cert_1.pem, cert_2.pem, ...
awk -v outdir="$TMPDIR" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = outdir "/cert_" n ".pem" }
    out { print > out }
    /-----END CERTIFICATE-----/   { out = "" }
' "$CHAIN_PEM"

# Walk the chain in order and dump subject + dates + SPKI hash.
i=0
for cert in "$TMPDIR"/cert_*.pem; do
    i=$((i + 1))
    subject="$(openssl x509 -in "$cert" -noout -subject | sed 's/^subject=//')"
    issuer="$(openssl x509 -in "$cert"  -noout -issuer  | sed 's/^issuer=//')"
    dates="$(openssl x509 -in "$cert"   -noout -dates   | tr '\n' '  ' | sed 's/  *$//')"
    spki="$(openssl x509 -in "$cert" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | openssl enc -base64)"
    printf '[%d] subject=%s\n' "$i" "$subject"
    printf '    issuer=%s\n' "$issuer"
    printf '    %s\n' "$dates"
    printf '    SPKI(SHA-256, b64): %s\n' "$spki"
    printf '\n'
done
