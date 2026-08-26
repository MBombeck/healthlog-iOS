#!/usr/bin/env python3
"""20-01 — the localhost wire the R4 separation is measured on.

R4 has two live explanations that must not be collapsed: the availability load
is still IN FLIGHT (congestion, the same shape as R3), or it NEVER COMPLETES.
Telling them apart needs the same walk run twice — once behind a healthy wire
and once behind a slow one — so this serves both roles from one file:

  * ``--upstream URL`` — a plain reverse proxy in front of a real seeded
    instance. Every response is held back by ``--delay`` seconds.
  * ``--seed FILE``    — a localhost origin that answers from a committed JSON
    route table, for when no seeded instance is reachable to the runner. Same
    ``--delay`` knob, same sockets, same HTTP.

No sudo, no Network Link Conditioner, nothing outside the repository. The app
supports self-hosted servers, so pointing it at ``http://127.0.0.1:<port>`` is
a supported path rather than a special build.

Usage
-----
    scripts/latency-proxy.py --seed scripts/fixtures/r4-availability-seed.json \
        --port 8787 --delay 0
    scripts/latency-proxy.py --upstream https://example.invalid \
        --port 8787 --delay 5

The delay is applied to the RESPONSE, after the upstream/seed work is done, so
it models a slow wire rather than a slow server.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hop-by-hop headers must not be forwarded (RFC 7230 6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class Config:
    def __init__(self, upstream: str | None, seed: dict | None, delay: float) -> None:
        self.upstream = upstream.rstrip("/") if upstream else None
        self.seed = seed or {}
        self.delay = delay
        self.hits: list[tuple[float, str, str]] = []
        self.lock = threading.Lock()

    def record(self, method: str, path: str) -> None:
        with self.lock:
            self.hits.append((time.time(), method, path))


CONFIG: Config


def _seed_response(path: str) -> tuple[int, bytes]:
    """Longest-prefix match against the seed table; unknown paths answer `{}`.

    An unknown route answering 200/`{}` rather than 404 is deliberate: this
    origin exists to measure ONE route's timing, and a 404 storm on the dozens
    of sibling routes the first paint opens would change what is being measured.
    """
    best_key = ""
    for key in CONFIG.seed:
        if path.startswith(key) and len(key) > len(best_key):
            best_key = key
    if not best_key:
        return 200, b"{}"
    entry = CONFIG.seed[best_key]
    status = int(entry.get("status", 200))
    body = entry.get("body", {})
    return status, json.dumps(body).encode("utf-8")


def _upstream_response(handler: BaseHTTPRequestHandler, body: bytes) -> tuple[int, bytes, list]:
    url = f"{CONFIG.upstream}{handler.path}"
    request = urllib.request.Request(url, data=body or None, method=handler.command)
    for name, value in handler.headers.items():
        if name.lower() in HOP_BY_HOP or name.lower() == "host":
            continue
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.read(), list(response.headers.items())
    except urllib.error.HTTPError as error:
        return error.code, error.read(), list(error.headers.items())
    except Exception as error:  # noqa: BLE001 — a dead upstream is data, not a crash
        payload = json.dumps({"data": None, "error": str(error)}).encode("utf-8")
        return 502, payload, []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002
        sys.stderr.write("latency-proxy: %s - %s\n" % (self.address_string(), fmt % args))

    def _serve(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        CONFIG.record(self.command, self.path)

        if CONFIG.upstream:
            status, payload, headers = _upstream_response(self, body)
        else:
            status, payload = _seed_response(self.path)
            headers = []

        if CONFIG.delay > 0:
            time.sleep(CONFIG.delay)

        self.send_response(status)
        forwarded = False
        for name, value in headers:
            if name.lower() in HOP_BY_HOP or name.lower() == "content-length":
                continue
            if name.lower() == "content-type":
                forwarded = True
            self.send_header(name, value)
        if not forwarded:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _serve
    do_POST = _serve
    do_PUT = _serve
    do_PATCH = _serve
    do_DELETE = _serve


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--delay", type=float, default=0.0, help="seconds held before each response")
    parser.add_argument("--upstream", default=None, help="forward to this origin")
    parser.add_argument("--seed", default=None, help="serve this JSON route table")
    args = parser.parse_args()

    if not args.upstream and not args.seed:
        parser.error("one of --upstream or --seed is required")

    seed = None
    if args.seed:
        with open(args.seed, encoding="utf-8") as handle:
            seed = json.load(handle)

    global CONFIG  # noqa: PLW0603 — one process, one configuration
    CONFIG = Config(upstream=args.upstream, seed=seed, delay=args.delay)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    mode = f"upstream={args.upstream}" if args.upstream else f"seed={args.seed}"
    sys.stderr.write(
        f"latency-proxy: listening on http://127.0.0.1:{args.port} {mode} delay={args.delay}s\n"
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        sys.stderr.write(f"latency-proxy: served {len(CONFIG.hits)} requests\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
