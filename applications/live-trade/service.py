"""Two single-tenant lab services. Each trade performs a real pooled SQLite read."""
import json
import os
import queue
import re
import sqlite3
import sys
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def otlp_value(value):
    if isinstance(value, dict):
        return {"kvlistValue": {"values": [
            {"key": key, "value": otlp_value(item)} for key, item in value.items()
        ]}}
    if isinstance(value, list):
        return {"arrayValue": {"values": [otlp_value(item) for item in value]}}
    if isinstance(value, int):
        return {"intValue": str(value)}
    return {"stringValue": value}


def emit(service, kind, summary, change, attributes):
    now = time.time_ns()
    event_id = str(uuid.uuid4())
    # An absolute time range keeps this link useful after the incident window closes.
    pane = {"datasource": "lab-loki", "queries": [{
        "refId": "A", "datasource": {"type": "loki", "uid": "lab-loki"},
        "expr": '{service_name="' + service + '"} |= "' + event_id + '"'
    }], "range": {"from": str(now // 1_000_000 - 60000), "to": str(now // 1_000_000 + 60000)}}
    link = os.environ["GRAFANA_URL"].rstrip("/") + "/explore?" + urlencode({
        "schemaVersion": "1", "panes": json.dumps({"log": pane}, separators=(",", ":"))
    })
    event = {
        "schemaVersion": "1.0", "eventId": event_id, "eventType": kind,
        "sourceId": service, "timestamp": datetime.fromtimestamp(now / 1e9, timezone.utc).isoformat(),
        "tenantId": "trading", "environment": "production", "changeId": change,
        "service": {"name": service, "namespace": "tenant-trading", "version": "1.0"},
        "severity": "ERROR" if kind in ("application.error", "trace.failure") else "INFO",
        "summary": summary, "attributes": attributes,
        "evidence": [{"type": "log", "system": "grafana", "url": link}]
    }
    batch = {"resourceLogs": [{
        "resource": {"attributes": [{"key": "service.name", "value": otlp_value(service)}]},
        "scopeLogs": [{"scope": {"name": "live-trade"}, "logRecords": [
            {"timeUnixNano": str(now), "body": otlp_value(event)}
        ]}]
    }]}
    req = Request(os.environ["OTLP_LOGS_URL"], data=json.dumps(batch).encode(),
                  headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=8) as response:
        response.read()
    return event_id


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"ready": True})
        try:
            if self.server.role == "trade-api" and self.path == "/trade":
                return self.trade()
            if self.server.role == "risk-service" and self.path == "/check":
                request_id = self.headers.get("X-Request-ID", "")
                if re.fullmatch("[0-9a-f]{32}", request_id):
                    return self.risk(request_id)
            self.reply(404, {})
        except (OSError, ValueError, KeyError) as exc:
            print(f"Dependency error: {type(exc).__name__}", file=sys.stderr, flush=True)
            self.reply(502, {"error": "dependency unavailable"})

    def risk(self, request_id):
        start = time.monotonic()
        change = self.server.change
        try:
            conn = self.server.pool.get(timeout=0.2)
        except queue.Empty:
            wait = round((time.monotonic() - start) * 1000)
            event = emit("risk-service", "application.error",
                         f"Database pool acquisition timed out during trade risk check after {change}.",
                         change, {"request.id": request_id, "pool.wait_ms": wait,
                                  "exception.type": "PoolTimeout", "pool.size": self.server.capacity})
            return self.reply(503, {"requestId": request_id, "changeId": change,
                                    "waitMs": wait, "riskEventId": event})
        wait = round((time.monotonic() - start) * 1000)
        try:
            # The query holds one real connection for the known duration of the demo risk check.
            conn.execute("SELECT risk_check()").fetchone()
        finally:
            self.server.pool.put(conn)
        self.reply(200, {"requestId": request_id, "changeId": change, "waitMs": wait})

    def trade(self):
        request_id = uuid.uuid4().hex
        req = Request(os.environ["RISK_URL"], headers={"X-Request-ID": request_id})
        try:
            risk = urlopen(req, timeout=15)
        except HTTPError as exc:
            if exc.code != 503:
                raise
            risk = exc
        with risk:
            status, details = risk.status, json.load(risk)
        change = details["changeId"]
        summary = (f"Production trade requests intermittently fail with HTTP 503 after change {change}: "
                   "risk-service timed out acquiring a database connection." if status == 503 else
                   f"Production trade request passed the risk check under change {change}.")
        event = emit("trade-api", "trace.failure" if status == 503 else "application.latency",
                     summary, change, {"trace.id": request_id, "request.id": request_id,
                                       "http.status_code": status, "pool.wait_ms": details["waitMs"]})
        self.reply(status, {**details, "tradeEventId": event})


def main():
    server = ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8080"))), Handler)
    server.role = os.environ["ROLE"]
    if server.role == "risk-service":
        server.capacity = int(os.getenv("POOL_SIZE", "4"))
        if not 1 <= server.capacity <= 16:
            raise ValueError("POOL_SIZE must be 1..16")
        server.pool = queue.Queue(maxsize=server.capacity)
        for _ in range(server.capacity):
            conn = sqlite3.connect(":memory:", check_same_thread=False)
            conn.create_function("risk_check", 0, lambda: time.sleep(0.8) or 1)
            server.pool.put(conn)
        server.change = os.environ["CHANGE_ID"]
        emit(server.role, "deployment.completed",
             f"Risk service deployed with database pool size {server.capacity} under change {server.change}.",
             server.change, {"pool.size": server.capacity})
    server.serve_forever()


if __name__ == "__main__":
    main()
