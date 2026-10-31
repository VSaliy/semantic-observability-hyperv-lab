"""Aggregation and idempotency against a real OpenSearch node (Testcontainers).

Skipped when no Docker-compatible runtime is reachable, unless REQUIRE_DOCKER_TESTS=1 (set in CI),
in which case a missing runtime fails the run instead of silently skipping it.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest
from opensearchpy import OpenSearch
from testcontainers.core.container import DockerContainer

from semantic_indexer.embeddings import DeterministicEmbeddingProvider
from semantic_indexer.opensearch_io import OpenSearchDocumentStore
from semantic_indexer.service import EventProcessor
from semantic_indexer.validation import EventValidator

ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = ROOT / "indexer" / "fixtures" / "seed-events.jsonl"
SCHEMA_PATH = ROOT / "schemas" / "operational-event.schema.json"
TEMPLATE_PATH = ROOT / "schemas" / "opensearch" / "index-template.json"
IMAGE = "docker.io/opensearchproject/opensearch:2.17.0"


class ListProducer:
  def __init__(self) -> None:
    self.messages: list[dict[str, Any]] = []

  def send(self, topic: str, value: dict[str, Any], key: str | None = None) -> None:
    self.messages.append(value)


@pytest.fixture(scope="module")
def opensearch_url() -> Iterator[str]:
  container = (
    DockerContainer(IMAGE)
    .with_env("discovery.type", "single-node")
    .with_env("DISABLE_SECURITY_PLUGIN", "true")
    .with_env("OPENSEARCH_JAVA_OPTS", "-Xms512m -Xmx512m")
    .with_exposed_ports(9200)
  )
  try:
    container.start()
  except Exception as exc:  # noqa: BLE001 - any failure here means no usable container runtime
    if os.environ.get("REQUIRE_DOCKER_TESTS") == "1":
      raise
    pytest.skip(f"no Docker-compatible runtime: {exc}")
  try:
    url = f"http://{container.get_container_host_ip()}:{container.get_exposed_port(9200)}"
    deadline = time.monotonic() + 180
    while True:
      try:
        if httpx.get(f"{url}/_cluster/health?wait_for_status=yellow", timeout=5).is_success:
          break
      except httpx.HTTPError:
        pass
      if time.monotonic() > deadline:
        raise TimeoutError(f"OpenSearch at {url} did not become ready")
      time.sleep(2)
    yield url
  finally:
    container.stop()


@pytest.fixture()
def alias(opensearch_url: str) -> str:
  """A fresh v2 index behind its own alias, created from the production template."""
  client = OpenSearch(opensearch_url)
  client.indices.put_index_template(
    name="observability-documents-v2-template",
    body=json.loads(TEMPLATE_PATH.read_text(encoding="utf-8")),
  )
  suffix = uuid.uuid4().hex[:8]
  index, alias_name = f"observability-documents-v2-{suffix}", f"observability-documents-{suffix}"
  client.indices.create(index=index)
  client.indices.put_alias(index=index, name=alias_name)
  return alias_name


def build(
  url: str, alias_name: str
) -> tuple[EventProcessor, OpenSearchDocumentStore, ListProducer]:
  store = OpenSearchDocumentStore(url, alias_name)
  producer = ListProducer()
  allowed_hosts = ["grafana.example", "kafka.example", "opensearch.example"]
  validator = EventValidator(str(SCHEMA_PATH), allowed_hosts)
  processor = EventProcessor(
    validator=validator,
    embedding_provider=DeterministicEmbeddingProvider(),
    store=store,
    dead_letter_producer=producer,
    dead_letter_topic="semantic.dead-letter",
    max_embedding_retries=1,
  )
  return processor, store, producer


def fixtures() -> list[dict[str, Any]]:
  lines = FIXTURE_PATH.read_text(encoding="utf-8").splitlines()
  return [json.loads(line) for line in lines if line]


def search_all(url: str, alias_name: str) -> list[dict[str, Any]]:
  client = OpenSearch(url)
  client.indices.refresh(index=alias_name)
  hits = client.search(index=alias_name, body={"size": 100, "query": {"match_all": {}}})
  return [hit["_source"] for hit in hits["hits"]["hits"]]


def test_replayed_events_converge_on_aggregates(opensearch_url: str, alias: str) -> None:
  events = fixtures()
  processor, _, producer = build(opensearch_url, alias)

  first = processor.process_messages(events)
  replay = processor.process_messages(reversed(events))

  assert (first.indexed, first.dead_lettered) == (len(events), 0)
  assert (replay.indexed, replay.duplicates) == (0, len(events))
  assert not producer.messages
  documents = search_all(opensearch_url, alias)
  assert len(documents) == 21
  assert sum(document["occurrences"] for document in documents) == len(events)

  by_type: dict[str, list[dict[str, Any]]] = {}
  for document in documents:
    if document["tenant_id"] == "trading":
      by_type.setdefault(document["document_type"], []).append(document)
  market_data = [document for document in documents if document["tenant_id"] == "market-data"]
  assert len(market_data) == 5
  payments = [document for document in documents if document["tenant_id"] == "payments"]
  assert len(payments) == 5
  (payments_incident,) = (
    document for document in payments if document["document_type"] == "incident"
  )
  assert payments_incident["incident_id"] == "INC-0101"
  assert payments_incident["status"] == "resolved"
  (market_incident,) = (
    document for document in market_data if document["document_type"] == "incident"
  )
  assert market_incident["incident_id"] == "INC-0077"
  assert market_incident["status"] != "resolved"
  pool_template = next(
    document for document in by_type["log_template"]
    if document["exception_type"] == "SQLTransientConnectionException"
  )
  assert pool_template["occurrences"] == 3
  assert len(pool_template["source_references"]) == 2
  (incident,) = by_type["incident"]
  assert incident["status"] == "resolved"
  assert incident["resolution"] == "restore previous pool configuration"
  assert all(len(document["semantic_vector"]) == 16 for document in documents)


def test_stale_write_is_rejected(opensearch_url: str, alias: str) -> None:
  processor, store, _ = build(opensearch_url, alias)
  event = fixtures()[0]
  processor.process_payload(event)
  document_id = search_all(opensearch_url, alias)[0]["document_id"]

  stored = store.get(document_id)
  assert stored is not None
  assert store.put(stored.document, stored)  # current version: accepted
  assert not store.put(stored.document, stored)  # same version again: now stale
  assert not store.put(stored.document, None)  # create over an existing document
