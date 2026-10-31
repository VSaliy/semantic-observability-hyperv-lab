#!/usr/bin/env bash
# Brings up the dev stack, seeds it, waits for indexing, and gates on the evaluation baseline.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

compose=(docker compose -f docker-compose.dev.yml)
expected_documents=${EXPECTED_DOCUMENTS:-16}

"${compose[@]}" up -d --build
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    "${compose[@]}" logs --no-color --tail 80 || true
  fi
  "${compose[@]}" down -v --remove-orphans
}
trap cleanup EXIT

wait_for() {
  local description=$1
  shift
  for _ in {1..60}; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for ${description}" >&2
  return 1
}

indexed_count() {
  curl -fsS http://localhost:9200/observability-documents/_count | python3 -c \
    'import json,sys; sys.exit(0 if json.load(sys.stdin)["count"] == int(sys.argv[1]) else 1)' \
    "$expected_documents"
}

query_api_ready() {
  local token
  token=$(python3 scripts/bootstrap/generate-dev-jwt.py)
  curl -fsS http://localhost:8080/api/v1/search \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d '{"query":"health","environment":"production","timeRange":"PT2H","topK":1,"mode":"HYBRID"}'
}

wait_for "OpenSearch" curl -fsS http://localhost:9200
wait_for "the query API" query_api_ready

python3 -m pip install -q -e ./semantic-search/indexer
PYTHONPATH=semantic-search/indexer/src python3 scripts/bootstrap/seed-events.py
wait_for "${expected_documents} indexed documents" indexed_count

python3 semantic-search/evaluation/evaluate_search.py --check-baseline semantic-search/evaluation/baseline.json
