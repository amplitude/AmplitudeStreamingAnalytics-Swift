#!/usr/bin/env python3
"""Test double for Amplitude's delayed-events endpoint, for local and CI testing of this SDK.

Python 3 stdlib only (no pip dependencies), so it runs on a stock GitHub macOS runner:

    python3 tools/mock_delayed_server.py --port 8123

**What this is.** A request recorder with real request validation and scriptable responses.
It exists to answer three questions a fake uploader cannot:

1.  Does the SDK's body survive a real ``URLSession`` round trip -- correct JSON, correct
    headers, correct URL?
2.  Would the endpoint *accept* it? Validation is reproduced faithfully, because a client
    cannot see a rejection coming: a body the SDK is perfectly happy with can be refused for
    being empty, or over the timeout ceiling, or missing a field, and the symptom in
    production is silently dropped data.
3.  Does the SDK handle the responses the endpoint actually returns, including the error and
    connection-failure paths, which ``/debug/script`` can queue on demand?

**What this is not.** It is not a re-implementation of the service, and it is deliberately
not the contract's source of truth -- staging verification against the real endpoint is.
There is no TTL expiry, no event ingestion, and no attempt to model what the backend does
with a stored payload after it is stored. An earlier version emulated all of that; almost
every test assertion it enabled turned out to be checking the emulation rather than the SDK,
and it was where every bug in this file lived. Assert on ``/debug/requests``.

**It is an independent implementation of the wire format on purpose.** It does not import the
SDK's ``DelayedRequestBody``. If the two shared a codec, a wrong field name on both sides
would match itself and the contract test would pass green.

The behaviour reproduced here was read from the service's source. Which source, at which
commit, and the full internal mapping -- including the divergences that are known and
deliberate -- are recorded outside this repo; see "Provenance" at the bottom of this
docstring. Keep this file describing only what a client can observe from outside.

Endpoints
---------
``POST /2/httpapi/delayed`` (and ``/2/httpapi/delayed/``)
    The delayed-events endpoint. Same path the real service serves, so a client configured
    with ``serverUrl = "http://localhost:8123/2/httpapi"`` reaches it unchanged --
    ``DelayedEventsHttpClient.getUrl()`` appends ``/delayed``.

``POST /2/httpapi``
    Amplitude HTTP V2 sink. **Fixture-only**: the real delayed-events service does not serve
    this path, and events it forwards go to a different host entirely. Collapsing them into
    one process lets a contract test point a single ``Configuration(serverUrl:)`` here and
    then assert that no video event reached the SDK's normal destination.

``GET /healthcheck``
    ``200 {"status": "ok"}``. Poll it to know the server is up before starting tests. The
    real service has a health endpoint too, but its response body is not reproduced here --
    do not assert on this shape.

``GET /debug/requests``
    The request log. Shape documented below. Consumed by the demo app's debug panel (Task 9b)
    and the Swift contract tests (Task 8 Step 3), so treat it as a published interface: add
    fields, do not rename or remove them. **This is where assertions belong.**

``GET /debug/state``
    The stored delayed payloads, as a convenience for a human watching the demo app. Nothing
    here is a faithful model of backend storage, so **tests must not assert on it** -- what
    the client sent is in ``/debug/requests``, which is the only thing the SDK controls.

``POST /debug/script``
    Queue responses for subsequent delayed requests, so a test can drive the SDK's error and
    retry paths. See "Scripting responses" below.

``POST /debug/reset``
    Drops the log, the stored payloads, the scripted queue and the throttle window.

Request log shape
-----------------
``GET /debug/requests`` -> ``{"count": <int>, "requests": [<request>, ...]}``, oldest first.
Only *completed* requests appear: a poller must never see a half-written entry, so an
in-flight request is absent rather than present with a null ``status``.

    {
      "seq":          1,                  # monotonic from 1, per server process
      "received_at":  1756312345678,      # epoch ms
      "method":       "POST",
      "path":         "/2/httpapi/delayed",
      "status":       200,                # HTTP status this server returned
      "api_key":      "test-api-key",     # parsed from the body; null if unparseable
      "id":           "vid-1",            # delay id; null on non-delayed routes
      "timeout":      5000,               # ms, as received; null if absent/uncoercible
      "events":       [ ... ],            # verbatim as received
      "instant_events": [ ... ],          # verbatim as received; [] when the key is absent
      "body":         { ... },            # whole parsed request body, verbatim; null if unparseable
      "raw_body":     null,               # request text, present ONLY when "body" is null
      "response":     { ... },            # exact JSON body returned; null if the socket was closed
      "error":        null,               # the error string, when status >= 400
      "scripted":     false,              # true when /debug/script supplied the response
      "actions":      ["store"]
    }

    "actions" is ordered and drawn from:
      "store"           the delayed payload was recorded   (timeout > 0, events non-empty)
      "flush"           timeout == 0, so the payload is finalized and dropped
      "drop"            the stored payload was removed
      "sink"            a POST /2/httpapi upload was absorbed
      "closed"          the connection was closed without a response (scripted)
      "unhandled"       a bug in this server -- an unexpected internal error. NOT set for the
                        faithful 500s, which are reproduction, not malfunction.

``GET /debug/state`` -> ``{"count": <int>, "entries": [{"api_key", "id", "timeout", "events",
"stored_at"}, ...]}``. Again: a debug aid, not a storage model. Do not assert on it.

Scripting responses
-------------------
``POST /debug/script`` with::

    {"queue": [{"status": 500, "body": {"error": "boom"}}, {"close": true}, {"status": 200}]}

Each subsequent ``POST /2/httpapi/delayed`` consumes one entry, in order; once the queue
drains, normal behaviour resumes. Entries take ``status`` (default 200), ``body`` (default
``{}``), and ``close`` -- which hangs up without responding, so the client sees a transport
error rather than an HTTP status. A scripted request is still validated and still logged,
with ``"scripted": true``, so a test can assert both what went out and how the SDK reacted.

``GET /debug/script`` returns what is still queued.

Behaviour reproduced faithfully
-------------------------------
Validation, in the endpoint's own order, with its exact error strings in its
``{"error": "..."}`` envelope: the kill switch (503), the payload ceiling (413), JSON parsing
and the empty-body case (400), then ``api_key``, ``id``, ``timeout``, the 24-hour timeout
ceiling, and the both-arrays-empty case (400), then api-key validity (400) and throttling
(429). Type coercion matches the endpoint's JSON library, including that an uncoercible field
type escapes to its catch-all 500 rather than producing a clean 400.

Response bodies: ``{"code": 200, "id": ...}`` plus ``"expiration"`` only when something was
stored, and ``{"code": 200, "id": ..., "flushed": true}`` when ``timeout == 0``. The
conditional ``expiration`` is easy to get wrong and the endpoint has a test for it.

Known simplifications, beyond the absent TTL/ingestion described above
----------------------------------------------------------------------
1.  **Only the catch-all 500 arises naturally.** Storage cannot fail here, so the endpoint's
    other 500s and its body-read 400 never occur on their own. Use ``/debug/script`` to
    drive a test through them.
2.  **No compression.** Stored payloads are plain dicts, and requests are not gzip-decoded
    (the SDK does not gzip delayed requests). The real payload ceiling applies to the
    *decompressed* body.
3.  **No accounts service.** Any non-empty ``api_key`` is valid unless ``--valid-api-key`` is
    passed, in which case anything else gets the endpoint's 400 ``"Invalid api_key"``.
4.  **Throttling is off by default** (``--throttle-gap-seconds 0``) and the kill switch is
    **on**, both the opposite of the real defaults. The real throttle gap is 1 second per
    api key and delay id, which a pulse-driven client trips constantly.
5.  **Unmatched methods and paths answer with JSON**, where the real server renders HTML.
6.  **No CORS handling** -- irrelevant to a native client.
7.  **Requests must declare a Content-Length.** A raw socket reader cannot find the end of a
    body on its own, so a chunked request, or one with no ``Content-Length``, reads as empty
    and gets 400 ``"Empty request body"``; the real service de-chunks and accepts it. For the
    same reason an *under*-declared ``Content-Length`` is not caught. ``URLSession`` always
    sets the header, so this bites hand-built fixtures only.
8.  **JSON parsing is strict.** ``json.loads`` is RFC 8259, where the endpoint's parser also
    accepts single quotes, unquoted keys and trailing commas. Hand-built fixtures again.

Provenance
----------
The endpoint's source, the commit it was read at, the mapping from these behaviours to it,
and the procedure for re-verifying after a backend change are in the project brain, under
``projects/video-analytics-mobile-sdk``. **Re-verify before trusting this file after any
backend change** -- nothing here is notified when the endpoint moves, so a stale fixture
keeps its tests green while the contract drifts underneath them.
"""

import argparse
import copy
import json
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_TIMEOUT_MS = 24 * 60 * 60 * 1000
DEFAULT_MAX_PAYLOAD_BYTES = 400_000

DELAYED_PATHS = ("/2/httpapi/delayed", "/2/httpapi/delayed/")
HTTPAPI_PATHS = ("/2/httpapi", "/2/httpapi/")


def now_ms():
    return int(time.time() * 1000)


class ServletError(Exception):
    """A response the endpoint produces as a status plus an exact error message."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class CloseConnection(Exception):
    """A scripted hang-up: the client should see a transport error, not an HTTP status."""


class CastError(Exception):
    """What the endpoint's JSON library raises on an uncoercible value.

    The endpoint does not catch it, so it surfaces as its catch-all 500 rather than a clean
    400. Reproduced rather than smoothed over: a client that trips it should see the same
    thing here as in staging.
    """


def cast_to_string(value):
    """Endpoint's getString: null passes through, scalars stringify."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value) if isinstance(value, float) else str(value)
    return json.dumps(value, separators=(",", ":"))


# Java's Long.parseLong grammar, which is stricter than Python's int(): no underscores and
# no surrounding whitespace.
_JAVA_LONG = re.compile(r"^[+-]?[0-9]+$")


def cast_to_long(value):
    """Endpoint's getLong: null/absent -> None, numbers and numeric strings cast.

    Being *more* permissive than the endpoint is the dangerous direction -- it lets a client
    the endpoint would reject pass a contract test -- so the string grammar is pinned to
    Java's. "", "null" and "NULL" are None and commas are stripped, both as the endpoint's
    JSON library does. Its ISO-8601 date fallback is not reproduced.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        raise CastError("can not cast to long, value : %s" % value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        if value in ("", "null", "NULL"):
            return None
        candidate = value.replace(",", "") if "," in value else value
        if _JAVA_LONG.match(candidate):
            return int(candidate)
        raise CastError("can not cast to long, value : %s" % value)
    raise CastError("can not cast to long, value : %s" % value)


def cast_to_array(value):
    """Endpoint's getJSONArray: null/absent -> None, a string is re-parsed."""
    if value is None:
        return None
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except ValueError:
            raise CastError("can not cast to JSONArray, value : %s" % value)
        if isinstance(parsed, list):
            return parsed
        raise CastError("can not cast to JSONArray, value : %s" % value)
    raise CastError("can not cast to JSONArray, value : %s" % value)


class MockState:
    """The request log, the scripted queue, and the debug-only stored payloads."""

    def __init__(self, options):
        self._lock = threading.RLock()
        self._options = options
        self._requests = []
        self._entries = {}  # (api_key, delay_id) -> debug-only stored payload
        self._script = []
        self._throttle = {}  # "apiKey:id" -> monotonic seconds of last accepted request
        self._request_seq = 0

    # -- request log ------------------------------------------------------------------

    def begin_request(self, method, path):
        with self._lock:
            self._request_seq += 1
            entry = {
                "seq": self._request_seq,
                "received_at": now_ms(),
                "method": method,
                "path": path,
                "status": None,
                "api_key": None,
                "id": None,
                "timeout": None,
                "events": [],
                "instant_events": [],
                "body": None,
                "raw_body": None,
                "response": None,
                "error": None,
                "scripted": False,
                "actions": [],
            }
            self._requests.append(entry)
            return entry

    def note_action(self, entry, action):
        with self._lock:
            entry["actions"].append(action)

    def complete_request(self, entry, status, payload, error):
        with self._lock:
            entry["status"] = status
            entry["response"] = payload
            entry["error"] = error

    # -- scripted responses -----------------------------------------------------------

    def queue_script(self, entries):
        with self._lock:
            self._script.extend(entries)
            return len(self._script)

    def next_script(self):
        with self._lock:
            return self._script.pop(0) if self._script else None

    def pending_script(self):
        with self._lock:
            return copy.deepcopy(self._script)

    # -- debug-only stored payloads ---------------------------------------------------

    def store(self, api_key, delay_id, timeout, events):
        with self._lock:
            self._entries[(api_key, delay_id)] = {
                "api_key": api_key,
                "id": delay_id,
                "timeout": timeout,
                "events": copy.deepcopy(events),
                "stored_at": now_ms(),
            }

    def drop(self, api_key, delay_id):
        with self._lock:
            return self._entries.pop((api_key, delay_id), None) is not None

    # -- throttle ---------------------------------------------------------------------

    def is_throttled(self, api_key, delay_id):
        gap = self._options.throttle_gap_seconds
        if gap <= 0:
            return False
        key = api_key + ":" + delay_id
        now = time.monotonic()
        with self._lock:
            last = self._throttle.get(key)
            if last is not None and (now - last) < gap:
                return True
            self._throttle[key] = now
            return False

    # -- debug views ------------------------------------------------------------------

    def snapshot_requests(self):
        """Completed requests only.

        An entry is created when a request arrives and filled in when it is answered, so
        publishing in-flight ones would hand a poller a half-written record with a null
        `status`. Consumers poll this endpoint, so that must never be observable.
        """
        with self._lock:
            done = [entry for entry in self._requests if entry["status"] is not None]
            return {"count": len(done), "requests": copy.deepcopy(done)}

    def snapshot_state(self):
        with self._lock:
            entries = [copy.deepcopy(self._entries[key]) for key in sorted(self._entries)]
            return {"count": len(entries), "entries": entries}

    def reset(self):
        with self._lock:
            self._requests.clear()
            self._entries.clear()
            self._script.clear()
            self._throttle.clear()
            self._request_seq = 0


class MockDelayedHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockDelayedEvents/2.0"

    # -- plumbing ---------------------------------------------------------------------

    @property
    def state(self):
        return self.server.state

    @property
    def options(self):
        return self.server.options

    def log_message(self, fmt, *args):
        if self.options.quiet:
            return
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _finish_request(self, entry, status, payload, error=None):
        self.state.complete_request(entry, status, payload, error)
        self._send_json(status, payload)

    def _fail(self, entry, status, message):
        """The endpoint's error envelope: {"error": message}."""
        self._finish_request(entry, status, {"error": message}, error=message)

    def _read_body(self, max_bytes):
        """Bounded read, rejecting an oversized body rather than buffering it.

        Unlike the endpoint, this has to trust Content-Length: `rfile` is a raw socket
        reader with no idea where the body ends, so reading past the declared length would
        block until the peer closed. See simplification 7.
        """
        raw_length = self.headers.get("Content-Length")
        try:
            declared = int(raw_length) if raw_length is not None else -1
        except ValueError:
            declared = -1
        if declared > max_bytes:
            # The body is left unread, so this connection can no longer be reused.
            self.close_connection = True
            raise ServletError(413, "Payload too large")
        data = self.rfile.read(declared) if declared > 0 else b""
        if len(data) > max_bytes:
            self.close_connection = True
            raise ServletError(413, "Payload too large")
        return data

    # -- routing ----------------------------------------------------------------------

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthcheck":
            self._send_json(200, {"status": "ok"})
            return
        if path == "/debug/requests":
            self._send_json(200, self.state.snapshot_requests())
            return
        if path == "/debug/state":
            self._send_json(200, self.state.snapshot_state())
            return
        if path == "/debug/script":
            self._send_json(200, {"queue": self.state.pending_script()})
            return
        if path in DELAYED_PATHS or path in HTTPAPI_PATHS:
            self._send_json(405, {"error": "Method Not Allowed"})
            return
        self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/debug/reset":
            self.state.reset()
            self._send_json(200, {"reset": True})
            return
        if path == "/debug/script":
            self._handle_script()
            return
        if path in DELAYED_PATHS:
            self._handle_delayed(path)
            return
        if path in HTTPAPI_PATHS:
            self._handle_httpapi(path)
            return
        self._send_json(404, {"error": "Not Found"})

    # -- POST /debug/script -----------------------------------------------------------

    def _handle_script(self):
        try:
            raw = self._read_body(self.options.max_payload_bytes)
        except ServletError as err:
            self._send_json(err.status, {"error": err.message})
            return
        try:
            body = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        except (ValueError, UnicodeDecodeError):
            self._send_json(400, {"error": "Invalid JSON"})
            return
        queue = body.get("queue") if isinstance(body, dict) else None
        if not isinstance(queue, list) or any(not isinstance(item, dict) for item in queue):
            self._send_json(400, {"error": "queue must be a list of objects"})
            return
        self._send_json(200, {"queued": self.state.queue_script(queue)})

    # -- POST /2/httpapi --------------------------------------------------------------

    def _handle_httpapi(self, path):
        """Amplitude HTTP V2 sink -- fixture-only, see the endpoint list."""
        entry = self.state.begin_request("POST", path)
        try:
            raw = self._read_body(self.options.max_payload_bytes)
        except ServletError as err:
            self._fail(entry, err.status, err.message)
            return

        try:
            body = json.loads(raw.decode("utf-8")) if raw.strip() else None
        except (ValueError, UnicodeDecodeError):
            body = None
        if not isinstance(body, dict):
            entry["raw_body"] = raw.decode("utf-8", "replace")
            self._fail(entry, 400, "Invalid JSON")
            return

        entry["body"] = copy.deepcopy(body)
        events = body.get("events")
        if not isinstance(events, list):
            events = []
        entry["api_key"] = cast_to_string(body.get("api_key"))
        entry["events"] = copy.deepcopy(events)

        self.state.note_action(entry, "sink")
        self._finish_request(entry, 200, {
            "code": 200,
            "events_ingested": len(events),
            "payload_size_bytes": len(raw),
            "server_upload_time": now_ms(),
        })

    # -- POST /2/httpapi/delayed ------------------------------------------------------

    def _handle_delayed(self, path):
        entry = self.state.begin_request("POST", path)
        try:
            self._handle_delayed_inner(entry)
        except CloseConnection:
            self.close_connection = True
            self.state.note_action(entry, "closed")
            self.state.complete_request(entry, 0, None, "connection closed by script")
        except ServletError as err:
            self._fail(entry, err.status, err.message)
        except CastError:
            # The endpoint's catch-all. Uncoercible field types land here.
            self._fail(entry, 500, "Internal server error")
        except Exception:  # pragma: no cover - last resort, mirrors the endpoint's own
            self.state.note_action(entry, "unhandled")
            self._fail(entry, 500, "Internal server error")

    def _handle_delayed_inner(self, entry):
        if not self.options.enabled:
            # Rejected before the body is read, as the endpoint does, so the connection
            # cannot be reused afterwards.
            self.close_connection = True
            raise ServletError(503, "Delayed events endpoint is not enabled")

        raw = self._read_body(self.options.max_payload_bytes)

        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            entry["raw_body"] = raw.decode("utf-8", "replace")
            raise ServletError(400, "Invalid JSON")

        # The endpoint's parser returns null for an empty document and throws for a
        # non-object one, which is why these two produce different messages.
        if text.strip() == "" or text.strip() == "null":
            entry["raw_body"] = text
            raise ServletError(400, "Empty request body")
        try:
            body = json.loads(text)
        except ValueError:
            entry["raw_body"] = text
            raise ServletError(400, "Invalid JSON")
        if not isinstance(body, dict):
            entry["raw_body"] = text
            raise ServletError(400, "Invalid JSON")

        entry["body"] = copy.deepcopy(body)

        api_key = cast_to_string(body.get("api_key"))
        delay_id = cast_to_string(body.get("id"))
        timeout = cast_to_long(body.get("timeout"))
        events = cast_to_array(body.get("events"))
        instant_events = cast_to_array(body.get("instant_events"))

        entry["api_key"] = api_key
        entry["id"] = delay_id
        entry["timeout"] = timeout
        entry["events"] = copy.deepcopy(events) if events is not None else []
        entry["instant_events"] = copy.deepcopy(instant_events) if instant_events is not None else []

        # Validation order is the endpoint's, and the messages are verbatim.
        if not api_key:
            raise ServletError(400, "Missing api_key")
        if not delay_id:
            raise ServletError(400, "Missing id")
        if timeout is None or timeout < 0:
            raise ServletError(400, "Missing or invalid timeout")
        if timeout > MAX_TIMEOUT_MS:
            raise ServletError(400, "Timeout exceeds maximum of 24 hours")
        if not events and not instant_events:
            raise ServletError(400, "Missing or empty events and instant_events")

        if events is None:
            events = []

        if self.options.valid_api_keys and api_key not in self.options.valid_api_keys:
            raise ServletError(400, "Invalid api_key")

        if self.state.is_throttled(api_key, delay_id):
            raise ServletError(429, "Too many requests")

        # Validation ran first, so a scripted response still proves the body was acceptable.
        scripted = self.state.next_script()
        if scripted is not None:
            entry["scripted"] = True
            if scripted.get("close"):
                raise CloseConnection()
            status = int(scripted.get("status", 200))
            payload = scripted.get("body", {})
            # Keep the log's own contract: `error` is set whenever status >= 400.
            error = payload.get("error") if status >= 400 and isinstance(payload, dict) else None
            self._finish_request(entry, status, payload, error=error)
            return

        if timeout == 0:
            # Finalized: the endpoint ingests everything in this request and drops the row.
            self.state.note_action(entry, "flush")
            if self.state.drop(api_key, delay_id):
                self.state.note_action(entry, "drop")
            self._finish_request(entry, 200, {"code": 200, "id": delay_id, "flushed": True})
            return

        # An instant-only request (empty events, instant_events present) deliberately does
        # not store: doing so would wipe a delayed payload already held under this id.
        if events:
            self.state.store(api_key, delay_id, timeout, events)
            self.state.note_action(entry, "store")

        response = {"code": 200, "id": delay_id}
        if events:
            # Only a stored delayed payload has an expiration.
            response["expiration"] = (now_ms() // 1000) + (timeout // 1000)
        self._finish_request(entry, 200, response)


class MockDelayedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, state, options):
        super().__init__(address, MockDelayedHandler)
        self.state = state
        self.options = options


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1",
                       help="bind address (default: %(default)s)")
    parser.add_argument("--port", type=int, default=8123,
                       help="listen port (default: %(default)s)")
    parser.add_argument("--max-payload-bytes", type=int, default=DEFAULT_MAX_PAYLOAD_BYTES,
                       help="413 above this, matching the endpoint's ceiling "
                            "(default: %(default)s)")
    parser.add_argument("--throttle-gap-seconds", type=float, default=0.0,
                       help="per api-key-and-delay-id gap enforced with 429; the real "
                            "default is 1, ours is 0 (off) because a pulsing client trips "
                            "it constantly (default: %(default)s)")
    parser.add_argument("--disabled", dest="enabled", action="store_false",
                       help="simulate the endpoint's kill switch being off, i.e. answer "
                            "every request with 503")
    parser.add_argument("--valid-api-key", dest="valid_api_keys", action="append", default=[],
                       metavar="KEY",
                       help="restrict to these api keys; anything else gets 400 "
                            "\"Invalid api_key\". Repeatable. Default: accept any non-empty key")
    parser.add_argument("--quiet", action="store_true", help="suppress the per-request log")
    return parser.parse_args(argv)


def main(argv=None):
    options = parse_args(argv if argv is not None else sys.argv[1:])
    state = MockState(options)
    server = MockDelayedServer((options.host, options.port), state, options)

    def shutdown(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    host, port = server.server_address[0], server.server_address[1]
    print("mock delayed-events server listening on http://%s:%d" % (host, port))
    print("  delayed endpoint: http://%s:%d%s" % (host, port, DELAYED_PATHS[0]))
    print("  request log:      http://%s:%d/debug/requests" % (host, port))
    sys.stdout.flush()

    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
