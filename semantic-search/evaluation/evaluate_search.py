#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

DATASET = Path(__file__).with_name("datasets").joinpath("evaluation-dataset.json")
TENANT_DOCUMENTS = Path(__file__).with_name("datasets").joinpath("tenant-documents.json")
API_URL = os.environ.get("SEARCH_API_URL", "http://localhost:8080/api/v1/search")


def get_token(tenant: str) -> str:
  return subprocess.check_output(
    [sys.executable, "scripts/bootstrap/generate-dev-jwt.py", tenant], text=True
  ).strip()


def precision_at_k(results: list[str], expected: set[str], k: int) -> float:
  top = results[:k]
  return sum(1 for result in top if result in expected) / k


def recall_at_k(results: list[str], expected: set[str], k: int) -> float:
  top = results[:k]
  return sum(1 for result in top if result in expected) / max(len(expected), 1)


def reciprocal_rank(results: list[str], expected: set[str]) -> float:
  for index, result in enumerate(results, start=1):
    if result in expected:
      return 1 / index
  return 0.0


def ndcg_at_k(results: list[str], expected: set[str], k: int) -> float:
  dcg = 0.0
  for index, result in enumerate(results[:k], start=1):
    if result in expected:
      dcg += 1 / math.log2(index + 1)
  ideal = sum(1 / math.log2(index + 1) for index in range(1, min(len(expected), k) + 1))
  return dcg / ideal if ideal else 0.0


def duration_from_range(start: str, end: str) -> str:
  start_ts = datetime.fromisoformat(start.replace("Z", "+00:00"))
  end_ts = datetime.fromisoformat(end.replace("Z", "+00:00"))
  total_seconds = int((end_ts - start_ts).total_seconds())
  hours, remainder = divmod(total_seconds, 3600)
  minutes, seconds = divmod(remainder, 60)
  duration = "PT"
  if hours:
    duration += f"{hours}H"
  if minutes:
    duration += f"{minutes}M"
  if seconds or duration == "PT":
    duration += f"{seconds}S"
  return duration


def main() -> None:
  dataset = json.loads(DATASET.read_text(encoding="utf-8"))
  tokens: dict[str, str] = {}
  tenant_documents: dict[str, list[str]] = json.loads(TENANT_DOCUMENTS.read_text(encoding="utf-8"))
  p5 = r10 = mrr = ndcg = latency = 0.0
  leakage = 0
  ranked = 0
  negatives = 0
  for entry in dataset:
    if entry["tenantId"] not in tokens:
      tokens[entry["tenantId"]] = get_token(entry["tenantId"])
    token = tokens[entry["tenantId"]]
    start = time.perf_counter()
    request = urllib.request.Request(
      API_URL,
      data=json.dumps({
        "query": entry["query"],
        "environment": entry["environment"],
        "timeRange": duration_from_range(entry["timeRange"]["from"], entry["timeRange"]["to"]),
        "topK": 10,
        "mode": "HYBRID"
      }).encode("utf-8"),
      headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer " + token
      },
      method="POST"
    )
    with urllib.request.urlopen(request, timeout=10) as response:
      payload = json.loads(response.read().decode("utf-8"))
    latency += time.perf_counter() - start
    results = [item.get("documentId") or item.get("summary") for item in payload["results"]]
    if payload["interpretedFilters"]["tenant"] != entry["tenantId"]:
      leakage += 1
    foreign = {
      document_id
      for tenant, ids in tenant_documents.items()
      if tenant != entry["tenantId"]
      for document_id in ids
    }
    leakage += sum(1 for result in results if result in foreign)
    expected = set(entry["expectedDocumentIds"])
    if not expected:
      negatives += 1
      continue
    ranked += 1
    p5 += precision_at_k(results, expected, 5)
    r10 += recall_at_k(results, expected, 10)
    mrr += reciprocal_rank(results, expected)
    ndcg += ndcg_at_k(results, expected, 10)
  total = ranked
  metrics = {
    "precisionAt5": round(p5 / total, 3),
    "recallAt10": round(r10 / total, 3),
    "mrr": round(mrr / total, 3),
    "ndcgAt10": round(ndcg / total, 3)
  }
  print(json.dumps({
    **metrics,
    "averageLatencySeconds": round(latency / len(dataset), 3),
    "rankedQuestions": ranked,
    "negativeControls": negatives,
    "crossTenantLeakageCount": leakage
  }, indent=2))
  failed = leakage > 0
  if len(sys.argv) == 3 and sys.argv[1] == "--check-baseline":
    baseline = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    tolerance = baseline["tolerance"]
    for name, value in metrics.items():
      if value < baseline[name] - tolerance:
        print(f"REGRESSION {name}: {value} < baseline {baseline[name]} - {tolerance}", file=sys.stderr)
        failed = True
  if failed:
    sys.exit(1)


if __name__ == "__main__":
  main()
