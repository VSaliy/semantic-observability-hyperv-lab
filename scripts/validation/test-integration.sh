#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

docker compose -f docker-compose.dev.yml up -d --build
trap 'docker compose -f docker-compose.dev.yml down -v --remove-orphans' EXIT

for _ in {1..30}; do
  if curl -fsS http://localhost:8080/actuator/health >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

python3 -m pip install -q -e ./semantic-search/indexer
PYTHONPATH=semantic-search/indexer/src python3 scripts/bootstrap/seed-events.py
sleep 10
TOKEN=$(./scripts/bootstrap/generate-dev-jwt.py)
response=$(curl -fsS http://localhost:8080/api/v1/search \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"query":"Why are production trade requests intermittently failing after the latest change?","environment":"production","timeRange":"PT2H","topK":5,"mode":"HYBRID"}')

echo "$response" | python3 -c 'import json,sys; payload=json.load(sys.stdin); assert payload["interpretedFilters"]["tenant"]=="trading"; assert payload["results"], payload'
