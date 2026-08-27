#!/usr/bin/env python3
"""Mock of Amplitude's delayed-events endpoint, for local and CI testing of this SDK.

Python 3 stdlib only (no pip dependencies), so it runs on a stock GitHub macOS runner:

    python3 tools/mock_delayed_server.py --port 8123

The behaviour below is an independent re-implementation of nova's
``projects/delayed-events/`` service (PR amplitude/nova#29664, since merged) --
``DelayedEventServlet.java``, ``DelayedEventDao.java``, ``DelayedEventUtils.java`` and
``DelayedEventSQSConsumer.java``. It is deliberately *not* built on the SDK's own
``DelayedRequestBody``: if the mock and the SDK shared a codec, a wrong field name on both
sides would match itself and the contract test would pass green.

Endpoints
---------
``POST /2/httpapi/delayed`` (and ``/2/httpapi/delayed/``)
    The delayed-events endpoint. Same path Jetty serves in nova
    (``DelayedEventServer.DELAYED_EVENTS_PATH``), so a client configured with
    ``serverUrl = "http://localhost:8123/2/httpapi"`` reaches it unchanged --
    ``DelayedEventsHttpClient.getUrl()`` appends ``/delayed``.

``POST /2/httpapi``
    Amplitude HTTP V2 ingestion sink. **This route does not exist on the real service** --
    nova maps only ``/2/httpapi/delayed``, ``/healthcheck`` and ``/elbcheck``, and the
    servlet forwards ingested events to a *different host*
    (``Config.DELAYED_EVENTS_EVENT_API_URL``, via ``InternalAmplitudeClient``). Collapsing
    the two into one process is a test-fixture choice: it lets a contract test point one
    ``Configuration(serverUrl:)`` here and then assert that no video event reached the
    normal destination. See divergence 8.

``GET /healthcheck``
    ``200 {"status": "ok"}``. Nova serves ``/healthcheck`` too, via ``HealthCheckServlet``;
    its response body has not been checked against this one, so do not assert on the shape.
    Poll it to know the server is up before starting tests.

``GET /debug/requests``, ``GET /debug/ingested``, ``GET /debug/state``
    Introspection. Shapes documented below -- these are consumed by the demo app's debug
    panel (Task 9b) and by the Swift contract tests (Task 8 Step 3), so treat them as a
    published interface: add fields, do not rename or remove them.

``POST /debug/reset``
    Drops all three logs plus the stored rows and the throttle window. Test isolation.

Debug payload shapes
--------------------
``GET /debug/requests`` -> ``{"count": <int>, "requests": [<request>, ...]}``, oldest first.
Only *completed* requests appear: a poller must never see a half-written entry, so an
in-flight request is absent rather than present with a null ``status``.

Each ``<request>`` is::

    {
      "seq":          1,                  # monotonic from 1, per server process
      "received_at":  1756312345678,      # epoch ms
      "method":       "POST",
      "path":         "/2/httpapi/delayed",
      "status":       200,                # HTTP status this server returned
      "api_key":      "test-api-key",     # parsed from the body; null if unparseable
      "id":           "vid-1",            # delay id; null on non-delayed routes
      "timeout":      5000,               # ms, as received; null if absent/uncoercible
      "events":       [ ... ],            # verbatim as received (before $time resolution)
      "instant_events": [ ... ],          # verbatim as received; [] when the key is absent
      "body":         { ... },            # whole parsed request body, verbatim; null if unparseable
      "raw_body":     null,               # request text, present ONLY when "body" is null
      "response":     { ... },            # exact JSON body this server returned
      "error":        null,               # the error string, when status >= 400
      "actions":      ["upsert", "ingest_instant"]
    }

    "actions" is ordered and drawn from:
      "upsert"          a row was stored/replaced        (timeout > 0, events non-empty)
      "ingest_instant"  instant_events were ingested     (timeout > 0)
      "flush"           timeout == 0 merge-and-ingest
      "delete"          the row was removed
      "ingest_direct"   a POST /2/httpapi upload was absorbed
      "unhandled"       a bug in this mock -- an unexpected internal error. NOT set for the
                        faithful 500s (an uncoercible field type), which are emulation, not
                        malfunction; if you see this, the mock itself broke.

``GET /debug/ingested`` -> ``{"count": <int>, "ingested": [<batch>, ...]}``, oldest first.
Everything that reached the (simulated) event API, one entry per ingest call::

    {
      "seq":          1,
      "at":           1756312345678,      # epoch ms
      "trigger":      "instant",          # "instant" | "flush" | "ttl" | "direct"
      "request_seq":  1,                  # the /debug/requests seq that caused it; null for "ttl"
      "api_key":      "test-api-key",
      "id":           "vid-1",            # delay id; null for "direct"
      "event_count":  1,
      "events":       [ ... ]             # post-$time-resolution, i.e. what the event API saw
    }

``GET /debug/state`` -> ``{"count": <int>, "rows": [<row>, ...]}``. The stored rows, i.e. the
DynamoDB table. Field names follow ``DelayedEventDao``'s attributes::

    {
      "id":         "test-api-key#vid-1", # composite key: apiKey + "#" + id
      "api_key":    "test-api-key",
      "delay_id":   "vid-1",
      "org_id":     1,
      "timeout_ms": 5000,
      "created_at": 1756312345678,        # epoch ms, if_not_exists -- survives replacement
      "updated_at": 1756312345678,        # epoch ms, last upsert
      "expiration": 1756312350,           # epoch SECONDS, TTL
      "event_data": { ... }               # the stored body; instant_events stripped, but
                                          # only when the request had a non-empty one --
                                          # a present-but-empty instant_events survives
    }

Deliberate divergences from the real service
--------------------------------------------
1.  **TTL fires promptly.** A sweeper thread expires rows within ``--ttl-tick-seconds`` of
    their ``expiration``. Real DynamoDB TTL deletion is best-effort and typically lags by
    minutes -- up to 48 hours -- before the Streams -> Lambda -> SQS -> consumer chain runs.
    Do not write a test that depends on the *latency* of the real thing being small.
2.  **Only the catch-all 500 is reachable; four other error paths are not.** ``_ingest``
    appends to a list and storage cannot fail, so the servlet's 400
    ``"Failed to read request body"``, 500 ``"Internal error"`` (upsert failure -- note this
    is a *different* string from the catch-all's ``"Internal server error"``), 500
    ``"Failed to ingest events"`` and 500 ``"Event ingestion interrupted"`` never occur here.
    No fault injection is implemented; the upsert-failure path in particular is a live
    contract branch with a test of its own in nova, so add injection before writing a
    negative test for it.
3.  **No zstd, no compression.** ``event_data`` is held as a dict rather than a compressed
    blob, and requests are not gzip-decoded (the SDK does not gzip delayed requests). Note
    the real server installs a Jetty ``GzipHandler``, so its 400,000-byte cap applies to the
    *decompressed* body.
4.  **No accounts service.** Any non-empty ``api_key`` is valid unless ``--valid-api-key``
    is passed, in which case anything else gets the servlet's 400 ``"Invalid api_key"``.
5.  **Throttling is off by default** (``--throttle-gap-seconds 0``), and the kill switch is
    **on** by default where nova's ``delayed.events.enabled`` defaults to false. The real
    throttle gap is 1 second per ``apiKey:id``, which a pulse-driven client trips constantly.
6.  **Unmatched methods and paths answer with JSON**, where Jetty renders HTML: ``GET`` on
    the delayed path gives a JSON 405, and an unknown path a JSON 404.
7.  **No CORS filter and no ``/elbcheck``** -- neither matters to a native client.
8.  **Requests must declare a Content-Length.** ``rfile`` cannot find the end of a body on
    its own, so a chunked request, or one with no ``Content-Length``, reads as empty and
    gets 400 ``"Empty request body"``; the real service de-chunks and accepts it. For the
    same reason an *under*-declared ``Content-Length`` is not caught here. ``URLSession``
    always sets the header, so this bites hand-built fixtures only. Also in this bucket:
    ``POST /2/httpapi`` is a fixture-only route (see the endpoint list above).
9.  **JSON parsing is strict.** ``json.loads`` is RFC 8259; fastjson runs with
    ``AllowUnQuotedFieldNames``, ``AllowSingleQuotes`` and ``AllowArbitraryCommas``, so a
    body with single quotes, bare keys or trailing commas is accepted there and 400
    ``"Invalid JSON"`` here. Again: hand-built fixtures, not ``JSONEncoder`` output.

Everything else is intended to match the servlet exactly, including the error strings, the
validation order, the ``"code"`` field in success responses, and the fact that ``expiration``
is omitted when nothing was stored.
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

# DelayedEventServlet.MAX_TIMEOUT_MS / DEFAULT_MAX_PAYLOAD_BYTES
MAX_TIMEOUT_MS = 24 * 60 * 60 * 1000
DEFAULT_MAX_PAYLOAD_BYTES = 400_000

# DelayedEventServer.DELAYED_EVENTS_PATH, plus the trailing-slash mapping Jetty also serves.
DELAYED_PATHS = ("/2/httpapi/delayed", "/2/httpapi/delayed/")
HTTPAPI_PATHS = ("/2/httpapi", "/2/httpapi/")

# The servlet looks the org id up from the api key via AccountsService; we have no accounts,
# so rows carry a fixed one. 1 is what nova's own servlet tests use.
STUB_ORG_ID = 1


def now_ms():
    return int(time.time() * 1000)


class ServletError(Exception):
    """A response the servlet produces via sendError: a status and an exact message."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class CastError(Exception):
    """What fastjson's TypeUtils raises on an uncoercible value.

    The servlet does not catch it, so doPost's catch-all turns it into
    500 "Internal server error". Emulated rather than smoothed over, because a client that
    sends a bool where a number belongs should see the same thing in both places.
    """


def cast_to_string(value):
    """fastjson JSONObject.getString: null passes through, scalars stringify."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value) if isinstance(value, float) else str(value)
    return json.dumps(value, separators=(",", ":"))


# Long.parseLong's grammar, which is stricter than Python's int(): no underscores, no
# surrounding whitespace, no unicode-digit look-alikes beyond what re's [0-9] matches.
_JAVA_LONG = re.compile(r"^[+-]?[0-9]+$")


def cast_to_long(value):
    """fastjson TypeUtils.castToLong: null/absent -> None, numbers and numeric strings cast.

    The string branch follows fastjson: "", "null" and "NULL" are None, commas are stripped,
    and anything else goes through `Long.parseLong`, which is narrower than Python's `int()`.
    Being *more* permissive than the real endpoint is the dangerous direction — it lets a
    client that the endpoint would 500 on pass a contract test — so the grammar is pinned.

    Not emulated: fastjson also falls back to scanning ISO-8601 date strings and returning
    epoch millis, so the real service turns `timeout: "2020-01-01T00:00:00Z"` into a number
    (then almost certainly 400s on the 24h cap) where this raises.
    """
    if value is None:
        return None
    if isinstance(value, bool):
        # Boolean is neither Number nor String to fastjson, so it reaches the throw.
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
    """fastjson JSONObject.getJSONArray: null/absent -> None, a string is re-parsed."""
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


def cast_to_object(value):
    """fastjson JSONArray.getJSONObject(int): a coercion, not an accessor.

    An object passes, null passes through, a string is re-parsed, and anything else --
    a number, a bool -- throws (ClassCastException / JSONException in Java). Nothing catches
    that inside the servlet, so a non-object element of `events` escapes to the catch-all 500.
    """
    if value is None:
        return None
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
        except ValueError:
            raise CastError("can not cast to JSONObject, value : %s" % value)
        if isinstance(parsed, dict):
            return parsed
        raise CastError("can not cast to JSONObject, value : %s" % value)
    raise CastError("can not cast to JSONObject, value : %s" % value)


def resolve_time_placeholders(events, timestamp_ms):
    """DelayedEventUtils.resolveTimePlaceholders -- in place, exact "$time" only.

    Every element goes through `getJSONObject`, so a non-object element raises here rather
    than being skipped. That is load-bearing: skipping it would let `events: [1]` return 200
    from this mock where the real service answers 500.
    """
    for index, event in enumerate(events):
        resolved = cast_to_object(event)
        if resolved is None:
            continue
        if resolved is not event:
            events[index] = resolved
        if resolved.get("time") == "$time":
            resolved["time"] = timestamp_ms


class MockState:
    """Stored rows plus the three debug logs. Every public method takes the lock."""

    def __init__(self, options):
        self._lock = threading.RLock()
        self._options = options
        self._rows = {}  # composite key -> row dict
        self._requests = []
        self._ingested = []
        self._throttle = {}  # "apiKey:id" -> monotonic seconds of last accepted request
        self._request_seq = 0
        self._ingest_seq = 0

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

    # -- rows -------------------------------------------------------------------------

    def upsert(self, api_key, delay_id, timeout_ms, event_data):
        """DelayedEventDao.upsert: full replace of event_data, created_at via if_not_exists."""
        stamp = now_ms()
        expiration = (stamp // 1000) + (timeout_ms // 1000)
        key = api_key + "#" + delay_id
        with self._lock:
            existing = self._rows.get(key)
            self._rows[key] = {
                "id": key,
                "api_key": api_key,
                "delay_id": delay_id,
                "org_id": STUB_ORG_ID,
                "timeout_ms": timeout_ms,
                "created_at": existing["created_at"] if existing else stamp,
                "updated_at": stamp,
                "expiration": expiration,
                "event_data": event_data,
            }

    def delete(self, api_key, delay_id):
        with self._lock:
            return self._rows.pop(api_key + "#" + delay_id, None) is not None

    # -- ingestion --------------------------------------------------------------------

    def ingest(self, api_key, delay_id, events, trigger, request_seq):
        """Stands in for InternalAmplitudeClient.ingest -- see divergence 2."""
        with self._lock:
            self._ingest_seq += 1
            self._ingested.append({
                "seq": self._ingest_seq,
                "at": now_ms(),
                "trigger": trigger,
                "request_seq": request_seq,
                "api_key": api_key,
                "id": delay_id,
                "event_count": len(events),
                "events": copy.deepcopy(events),
            })

    # -- throttle ---------------------------------------------------------------------

    def is_throttled(self, api_key, delay_id):
        """SimpleThrottler over "delayed-events:" + apiKey + ":" + id."""
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

    # -- TTL --------------------------------------------------------------------------

    def sweep_expired(self):
        """Rows past their TTL: delete first, then ingest. Not transactional, as in nova.

        The SQS consumer resolves "$time" against the row's updated_at rather than the
        expiry instant, and drops rows with no api_key or no events.
        """
        now_s = int(time.time())
        with self._lock:
            expired = [row for row in self._rows.values() if row["expiration"] <= now_s]
            for row in expired:
                del self._rows[row["id"]]

        for row in expired:
            event_data = row["event_data"] if isinstance(row["event_data"], dict) else {}
            api_key = cast_to_string(event_data.get("api_key"))
            try:
                # getJSONArray, so a stored `events` that is a JSON-array *string* still
                # ingests -- the consumer re-parses it rather than dropping the row.
                events = cast_to_array(event_data.get("events"))
            except CastError:
                events = None
            if not api_key or not events:
                continue
            events = copy.deepcopy(events)
            try:
                resolve_time_placeholders(events, row["updated_at"])
            except CastError as err:
                # The consumer's catch swallows this and never deletes the SQS message, so
                # the payload redelivers until the DLQ claims it -- i.e. it is never ingested.
                sys.stderr.write("ttl ingest dropped for id=%s: %s\n" % (row["delay_id"], err))
                sys.stderr.flush()
                continue
            self.ingest(api_key, row["delay_id"], events, "ttl", None)

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

    def snapshot_ingested(self):
        with self._lock:
            return {"count": len(self._ingested), "ingested": copy.deepcopy(self._ingested)}

    def snapshot_state(self):
        with self._lock:
            rows = [copy.deepcopy(self._rows[key]) for key in sorted(self._rows)]
            return {"count": len(rows), "rows": rows}

    def reset(self):
        with self._lock:
            self._rows.clear()
            self._requests.clear()
            self._ingested.clear()
            self._throttle.clear()
            self._request_seq = 0
            self._ingest_seq = 0


class MockDelayedHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockDelayedEvents/1.0"

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
        """DelayedEventServlet.sendError: {"error": message}."""
        self._finish_request(entry, status, {"error": message}, error=message)

    def _read_body(self, max_bytes):
        """The servlet's bounded read: at most max_bytes + 1, so an oversized body costs
        one byte past the cap rather than unbounded heap.

        Unlike the servlet, this one has to trust Content-Length: `rfile` is a raw socket
        reader with no idea where the body ends, so reading past the declared length would
        block until the peer closed. That makes the declared length load-bearing here and
        merely a fast path there -- see divergence 8.
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
        if path == "/debug/ingested":
            self._send_json(200, self.state.snapshot_ingested())
            return
        if path == "/debug/state":
            self._send_json(200, self.state.snapshot_state())
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
        if path in DELAYED_PATHS:
            self._handle_delayed(path)
            return
        if path in HTTPAPI_PATHS:
            self._handle_httpapi(path)
            return
        self._send_json(404, {"error": "Not Found"})

    # -- POST /2/httpapi --------------------------------------------------------------

    def _handle_httpapi(self, path):
        """Amplitude HTTP V2. Not part of the delayed contract -- here so one server can
        also be the SDK's normal destination (see the module docstring)."""
        entry = self.state.begin_request("POST", path)
        try:
            raw = self._read_body(self.options.max_payload_bytes)
        except ServletError as err:
            self._fail(entry, err.status, err.message)
            return

        try:
            body = json.loads(raw.decode("utf-8")) if raw.strip() else None
        except (ValueError, UnicodeDecodeError):
            entry["raw_body"] = raw.decode("utf-8", "replace")
            self._fail(entry, 400, "Invalid JSON")
            return

        if not isinstance(body, dict):
            entry["raw_body"] = raw.decode("utf-8", "replace")
            self._fail(entry, 400, "Invalid JSON")
            return

        entry["body"] = copy.deepcopy(body)
        api_key = cast_to_string(body.get("api_key"))
        events = body.get("events")
        if not isinstance(events, list):
            events = []
        entry["api_key"] = api_key
        entry["events"] = copy.deepcopy(events)

        self.state.ingest(api_key, None, events, "direct", entry["seq"])
        self.state.note_action(entry, "ingest_direct")
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
        except ServletError as err:
            self._fail(entry, err.status, err.message)
        except CastError:
            # doPost's catch-all. Uncoercible field types land here, as in fastjson.
            self._fail(entry, 500, "Internal server error")
        except Exception:  # pragma: no cover - matches the servlet's own last resort
            self.state.note_action(entry, "unhandled")
            self._fail(entry, 500, "Internal server error")

    def _handle_delayed_inner(self, entry):
        if not self.options.enabled:
            # Rejected before the body is read, as in the servlet, so the connection
            # cannot be reused afterwards.
            self.close_connection = True
            raise ServletError(503, "Delayed events endpoint is not enabled")

        raw = self._read_body(self.options.max_payload_bytes)

        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            entry["raw_body"] = raw.decode("utf-8", "replace")
            raise ServletError(400, "Invalid JSON")

        # fastjson's parseObject returns null for an empty document and throws for a
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

        # Validation order is the servlet's, and the messages are verbatim.
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

        has_instant_events = bool(instant_events)

        if timeout == 0:
            # flushImmediately: merge, resolve, ingest from the request body, then delete.
            merged = copy.deepcopy(events)
            if has_instant_events:
                merged.extend(copy.deepcopy(instant_events))
            resolve_time_placeholders(merged, now_ms())
            self.state.ingest(api_key, delay_id, merged, "flush", entry["seq"])
            self.state.note_action(entry, "flush")
            if self.state.delete(api_key, delay_id):
                self.state.note_action(entry, "delete")
            self._finish_request(entry, 200, {"code": 200, "id": delay_id, "flushed": True})
            return

        # Only persist when there are delayed events to store. An instant-only request
        # (empty events, instant_events present) must not upsert -- doing so would wipe a
        # delayed payload already stored under this id. This is explicit in the servlet.
        if events:
            event_data = copy.deepcopy(body)
            if has_instant_events:
                # Stripped only when instants are actually present: a present-but-empty
                # instant_events key stays in the stored body, exactly as in the servlet.
                event_data.pop("instant_events", None)
            self.state.upsert(api_key, delay_id, timeout, event_data)
            self.state.note_action(entry, "upsert")

        if has_instant_events:
            # The ordering guarantee: if an upsert was owed, this is reached only because it
            # succeeded. An instant-only request owes none and still ingests.
            to_ingest = copy.deepcopy(instant_events)
            resolve_time_placeholders(to_ingest, now_ms())
            self.state.ingest(api_key, delay_id, to_ingest, "instant", entry["seq"])
            self.state.note_action(entry, "ingest_instant")

        response = {"code": 200, "id": delay_id}
        if events:
            # Only a stored delayed event has an expiration.
            response["expiration"] = (now_ms() // 1000) + (timeout // 1000)
        self._finish_request(entry, 200, response)


class MockDelayedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, state, options):
        super().__init__(address, MockDelayedHandler)
        self.state = state
        self.options = options


def ttl_sweeper(state, options, stop_event):
    while not stop_event.wait(options.ttl_tick_seconds):
        try:
            state.sweep_expired()
        except Exception as err:  # pragma: no cover - a sweep must not kill the thread
            sys.stderr.write("ttl sweep failed: %s\n" % err)
            sys.stderr.flush()


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
                       help="413 above this; nova's delayed.events.max.payload.bytes "
                            "(default: %(default)s)")
    parser.add_argument("--throttle-gap-seconds", type=float, default=0.0,
                       help="per apiKey:id gap enforced with 429; nova's default is 1, ours "
                            "is 0 (off) because a pulsing client trips it constantly "
                            "(default: %(default)s)")
    parser.add_argument("--disabled", dest="enabled", action="store_false",
                       help="simulate the delayed.events.enabled kill switch being off, "
                            "i.e. answer every request with 503")
    parser.add_argument("--valid-api-key", dest="valid_api_keys", action="append", default=[],
                       metavar="KEY",
                       help="restrict to these api keys; anything else gets 400 "
                            "\"Invalid api_key\". Repeatable. Default: accept any non-empty key")
    parser.add_argument("--ttl-tick-seconds", type=float, default=0.25,
                       help="TTL sweep interval (default: %(default)s)")
    parser.add_argument("--no-ttl", dest="ttl", action="store_false",
                       help="never expire stored rows")
    parser.add_argument("--quiet", action="store_true", help="suppress the per-request log")
    return parser.parse_args(argv)


def main(argv=None):
    options = parse_args(argv if argv is not None else sys.argv[1:])
    state = MockState(options)
    server = MockDelayedServer((options.host, options.port), state, options)

    stop_event = threading.Event()
    if options.ttl:
        threading.Thread(target=ttl_sweeper, args=(state, options, stop_event),
                         daemon=True).start()

    def shutdown(_signum, _frame):
        stop_event.set()
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
        stop_event.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
