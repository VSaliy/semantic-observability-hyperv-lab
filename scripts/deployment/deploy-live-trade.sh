#!/usr/bin/env bash
set -euo pipefail
context=${1:?Usage: bash deploy-live-trade.sh CONTEXT --issuer HTTPS_URL --audience AUD --indexer-image REF --query-image REF}
shift
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
k=(kubectl --context "$context")
for ns in tenant-trading tenant-market-data platform-search platform-observability platform-messaging; do
  "${k[@]}" get namespace "$ns" >/dev/null
done
"${k[@]}" -n platform-observability get secret live-grafana-admin >/dev/null
manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
python3 "$root/kubernetes/live-trade/render.py" "$@" > "$manifest"
"${k[@]}" apply --dry-run=server -f "$manifest" >/dev/null
"${k[@]}" apply -f "$manifest"
for component in platform-messaging/kafka platform-search/opensearch platform-search/embedding-service \
    platform-search/semantic-indexer platform-observability/loki platform-observability/grafana \
    platform-observability/collector platform-search/query-api tenant-trading/risk-service tenant-trading/trade-api; do
  "${k[@]}" -n "${component%/*}" rollout status "deployment/${component#*/}" --timeout=5m
done
