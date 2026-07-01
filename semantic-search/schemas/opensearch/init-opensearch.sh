#!/usr/bin/env sh
set -eu
OS_URL="${OPENSEARCH_URL:-http://opensearch:9200}"
until curl -fsS "$OS_URL" >/dev/null; do
  echo "waiting for OpenSearch at $OS_URL"
  sleep 5
done
curl -fsS -X PUT "$OS_URL/_index_template/observability-documents-v1-template" \
  -H 'Content-Type: application/json' \
  --data-binary @/assets/index-template.json
curl -fsS -X PUT "$OS_URL/observability-documents-v1" >/dev/null || true
curl -fsS -X POST "$OS_URL/_aliases" -H 'Content-Type: application/json' -d '{"actions":[{"add":{"index":"observability-documents-v1","alias":"observability-documents"}}]}' >/dev/null || true
