"""Exercise the live-trade profile and save the response and the supporting Loki record."""
import argparse
import base64
import concurrent.futures
import json
import os
import signal
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen


QUESTION = "Why are production trade requests intermittently failing after the latest change?"


def http(url, *, headers=None, data=None):
    req = Request(url, headers=headers or {}, data=None if data is None else json.dumps(data).encode())
    try:
        response = urlopen(req, timeout=20)
    except HTTPError as exc:
        if exc.code != 503:
            raise
        response = exc
    with response:
        return response.status, json.load(response)


def change_pool(kube, before, after):
    deployment = json.loads(subprocess.check_output(kube + ["get", "deploy/risk-service", "-o", "json"]))
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    if container["name"] != "risk-service":
        raise ValueError("Unexpected risk-service container")
    ops = []
    for key, old_value in before.items():
        i = next(i for i, item in enumerate(container["env"]) if item["name"] == key)
        path = f"/spec/template/spec/containers/0/env/{i}/value"
        ops.extend([{"op": "test", "path": path, "value": old_value},
                    {"op": "replace", "path": path, "value": after[key]}])
    subprocess.run(kube + ["patch", "deployment/risk-service", "--type=json", "-p", json.dumps(ops)], check=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--context", required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--trade", default="http://127.0.0.1:18081")
    p.add_argument("--search", default="http://127.0.0.1:18080")
    p.add_argument("--grafana", default="http://127.0.0.1:3000")
    args = p.parse_args()
    tokens = {t: os.environ[var] for t, var in
              [("trading", "TRADING_TOKEN"), ("market-data", "MARKET_DATA_TOKEN")]}
    grafana_auth = base64.b64encode(("admin:" + os.environ["GRAFANA_PASSWORD"]).encode()).decode()
    kube = ["kubectl", "--context", args.context, "-n", "tenant-trading"]
    ready = kube + ["rollout", "status", "deploy/risk-service", "--timeout=180s"]
    start = time.time()
    change = "CHG-" + uuid.uuid4().hex[:12]
    original = {"POOL_SIZE": "4", "CHANGE_ID": "baseline"}
    reduced = {"POOL_SIZE": "1", "CHANGE_ID": change}
    report = {"changeId": change, "started": datetime.now(timezone.utc).isoformat()}

    def trade():
        status, body = http(args.trade + "/trade")
        return {"status": status, **body}

    def verify_batch(batch, expected_change):
        if any(row["changeId"] != expected_change for row in batch):
            raise ValueError("Responses came from an unexpected rollout")

    def search(tenant):
        duration = int(time.time() - start) + 5
        headers = {"Authorization": "Bearer " + tokens[tenant], "Content-Type": "application/json"}
        _, payload = http(args.search + "/api/v1/search", headers=headers, data={
            "query": QUESTION, "environment": "production", "timeRange": f"PT{duration}S",
            "topK": 5, "mode": "HYBRID"})
        if payload["interpretedFilters"]["tenant"] != tenant:
            raise ValueError("Unexpected tenant scope")
        return payload

    def interrupted(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Check authentication before changing the workload configuration.
    for tenant in tokens:
        search(tenant)
    report["healthy"] = trade()
    if report["healthy"]["status"] != 200 or report["healthy"]["changeId"] != "baseline":
        raise ValueError("Expected a successful baseline trade")
    change_pool(kube, original, reduced)
    try:
        subprocess.run(ready, check=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            batch = list(pool.map(lambda _: trade(), range(4)))
        report["duringChange"] = batch
        verify_batch(batch, change)
        if {row["status"] for row in batch} != {200, 503}:
            raise ValueError("Expected both successful trades and pool timeouts")
    finally:
        try:
            args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
        finally:
            change_pool(kube, reduced, original)
            subprocess.run(ready, check=True)
    report["recovered"] = trade()
    if report["recovered"]["status"] != 200 or report["recovered"]["changeId"] != "baseline":
        raise ValueError("Risk service did not recover")
    failed_ids = {r[key] for r in batch if r["status"] == 503 for key in ("riskEventId", "tradeEventId")}
    # Poll for ingestion. Prove the link's actual Explore query retrieves the source event.
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        response = search("trading")
        report["response"] = response
        for hit in response["results"]:
            for link in hit["evidence"]:
                url = urlsplit(link["url"])
                if url.netloc != urlsplit(args.grafana).netloc or url.path != "/explore":
                    continue
                pane = json.loads(parse_qs(url.query)["panes"][0])["log"]
                expr = pane["queries"][0]["expr"]
                event_id = next((eid for eid in failed_ids if eid in expr), None)
                if not event_id:
                    continue
                params = urlencode({"query": expr, "start": int(pane["range"]["from"]) * 10**6,
                                    "end": int(pane["range"]["to"]) * 10**6})
                _, logs = http(args.grafana + "/api/datasources/proxy/uid/lab-loki/loki/api/v1/query_range?" + params,
                               headers={"Authorization": "Basic " + grafana_auth})
                for stream in logs["data"]["result"]:
                    for _, line in stream["values"]:
                        record = json.loads(line)
                        if record["eventId"] == event_id and record["changeId"] == change:
                            foreign = search("market-data")
                            if foreign["results"]:
                                raise ValueError("Expected no market-data results in this isolated profile")
                            report.update(sourceLog=record, evidenceLink=link["url"], marketDataResponse=foreign)
                            args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
                            print(f"Verified {change}, recovery and tenant isolation. Report: {args.output}")
                            return
        time.sleep(2)
    args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    raise SystemExit("The live results did not link to a matching source log within 120 seconds")


if __name__ == "__main__":
    main()
