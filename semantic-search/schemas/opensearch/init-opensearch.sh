#!/usr/bin/env sh
set -eu
OS_URL="${OPENSEARCH_URL:-http://opensearch:9200}"
ALIAS="observability-documents"
INDEX="observability-documents-v2"
PREVIOUS="observability-documents-v1"

until curl -fsS "$OS_URL" >/dev/null; do
  echo "waiting for OpenSearch at $OS_URL"
  sleep 5
done

curl -fsS -X PUT "$OS_URL/_index_template/$INDEX-template" \
  -H 'Content-Type: application/json' \
  --data-binary @/assets/index-template.json
echo
# The v1 template must not shape new indices any more.
curl -sS -o /dev/null -X DELETE "$OS_URL/_index_template/$PREVIOUS-template" || true

if ! curl -fs -o /dev/null -I "$OS_URL/$INDEX"; then
  curl -fsS -X PUT "$OS_URL/$INDEX" >/dev/null
  echo "created $INDEX"
fi

# Move the alias atomically. v1 documents have a different shape and are not reindexed;
# rebuild v2 by replaying Kafka (see docs/architecture/semantic-indexing.md).
if curl -fs -o /dev/null "$OS_URL/$PREVIOUS/_alias/$ALIAS"; then
  actions="{\"actions\":[{\"remove\":{\"index\":\"$PREVIOUS\",\"alias\":\"$ALIAS\"}},{\"add\":{\"index\":\"$INDEX\",\"alias\":\"$ALIAS\"}}]}"
  echo "moving alias $ALIAS from $PREVIOUS to $INDEX"
else
  actions="{\"actions\":[{\"add\":{\"index\":\"$INDEX\",\"alias\":\"$ALIAS\"}}]}"
fi
curl -fsS -X POST "$OS_URL/_aliases" -H 'Content-Type: application/json' -d "$actions" >/dev/null
echo "alias $ALIAS -> $INDEX"
