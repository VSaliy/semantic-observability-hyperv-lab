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
python3 semantic-search/evaluation/capture_flagship.py
