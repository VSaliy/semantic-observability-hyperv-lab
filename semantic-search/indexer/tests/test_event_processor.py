from __future__ import annotations

import copy
import hashlib
import json
import random
from pathlib import Path
from typing import Any

import pytest

from semantic_indexer.documents import deterministic_document_id
from semantic_indexer.embeddings import DeterministicEmbeddingProvider
from semantic_indexer.models import SemanticDocument
from semantic_indexer.service import EventProcessor, StoredDocument
from semantic_indexer.validation import EventValidator

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "seed-events.jsonl"
SCHEMA_PATH = Path(__file__).resolve().parents[2] / "schemas" / "operational-event.schema.json"
SECRET = "jdbc:postgresql://db.internal/trading"


class InMemoryStore:
  """Versioned store with the same optimistic-concurrency contract as OpenSearch."""

  def __init__(self) -> None:
    self._documents: dict[str, tuple[SemanticDocument, int]] = {}
    self.injected_conflicts = 0

  def get(self, document_id: str) -> StoredDocument | None:
    entry = self._documents.get(document_id)
    if entry is None:
      return None
    return StoredDocument(document=entry[0].model_copy(deep=True), version=entry[1])

  def put(self, document: SemanticDocument, expected: StoredDocument | None) -> bool:
    if self.injected_conflicts:
      self.injected_conflicts -= 1
      return False
    current = self._documents.get(document.document_id)
    if (current[1] if current else None) != (expected.version if expected else None):
      return False
    version = current[1] + 1 if current else 1
    self._documents[document.document_id] = (document.model_copy(deep=True), version)
    return True

  @property
  def documents(self) -> dict[str, dict[str, Any]]:
    return {key: value[0].model_dump(mode="json") for key, value in self._documents.items()}

  def of_type(self, document_type: str) -> list[dict[str, Any]]:
    return [doc for doc in self.documents.values() if doc["document_type"] == document_type]


class InMemoryProducer:
  def __init__(self) -> None:
    self.messages: list[dict[str, Any]] = []

  def send(self, topic: str, value: dict[str, Any], key: str | None = None) -> None:
    self.messages.append({"topic": topic, "value": value, "key": key})


class RecordingEmbedder(DeterministicEmbeddingProvider):
  def __init__(self) -> None:
    self.texts: list[str] = []

  def embed(self, text: str) -> list[float]:
    self.texts.append(text)
    return super().embed(text)


class FailingEmbedder:
  def __init__(self, failures: int) -> None:
    self.failures = failures
    self.calls = 0

  def embed(self, text: str) -> list[float]:
    self.calls += 1
    if self.calls <= self.failures:
      raise RuntimeError("embedding unavailable")
    return [0.1] * 16


@pytest.fixture(autouse=True)
def no_retry_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
  monkeypatch.setattr("semantic_indexer.service.time.sleep", lambda _seconds: None)


@pytest.fixture()
def events() -> dict[str, dict[str, Any]]:
  lines = FIXTURE_PATH.read_text(encoding="utf-8").splitlines()
  return {payload["eventId"]: payload for payload in (json.loads(line) for line in lines if line)}


@pytest.fixture()
def validator() -> EventValidator:
  allowed = ["grafana.example", "kafka.example", "opensearch.example"]
  return EventValidator(str(SCHEMA_PATH), allowed)


def build_processor(
  validator: EventValidator, embedder: Any | None = None, store: InMemoryStore | None = None
) -> tuple[EventProcessor, InMemoryStore, InMemoryProducer]:
  store = store or InMemoryStore()
  producer = InMemoryProducer()
  processor = EventProcessor(
    validator=validator,
    embedding_provider=embedder or DeterministicEmbeddingProvider(),
    store=store,
    dead_letter_producer=producer,
    dead_letter_topic="semantic.dead-letter",
    max_embedding_retries=3
  )
  return processor, store, producer


def test_valid_event_creates_document(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  result = processor.process_payload(events["evt-0001"])
  assert result.indexed == 1
  assert len(store.documents) == 1


def test_invalid_event_reaches_dead_letter_topic(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  invalid = dict(events["evt-0001"])
  invalid.pop("tenantId")
  processor, _, producer = build_processor(validator)
  result = processor.process_payload(invalid)
  assert result.dead_lettered == 1
  assert producer.messages[0]["topic"] == "semantic.dead-letter"


def test_duplicate_delivery_creates_no_duplicate(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_payload(events["evt-0002"])
  result = processor.process_payload(events["evt-0002"])
  assert result.duplicates == 1
  assert result.indexed == 0
  (document,) = store.documents.values()
  assert document["occurrences"] == 1
  assert document["event_ids"] == ["evt-0002"]


def test_redacted_values_never_reach_opensearch(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  embedder = RecordingEmbedder()
  processor, store, _ = build_processor(validator, embedder)
  processor.process_payload(events["evt-0002"])
  assert SECRET not in json.dumps(store.documents)
  assert embedder.texts
  assert all(SECRET not in text for text in embedder.texts)


def test_tenant_id_is_mandatory(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  invalid = dict(events["evt-0001"])
  invalid["tenantId"] = ""
  processor, store, producer = build_processor(validator)
  processor.process_payload(invalid)
  assert producer.messages
  assert not store.documents


def test_evidence_references_survive_transformation(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_messages(events[event_id] for event_id in ("evt-0002", "evt-0010", "evt-0011"))
  (document,) = store.of_type("log_template")
  urls = {reference["url"] for reference in document["source_references"]}
  expected = {
    reference["url"]
    for event_id in ("evt-0002", "evt-0010", "evt-0011")
    for reference in events[event_id]["evidence"]
  }
  assert urls == expected


def test_embedding_failure_uses_bounded_retries(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  embedder = FailingEmbedder(3)
  processor, store, producer = build_processor(validator, embedder)
  processor.process_payload(events["evt-0001"])
  assert embedder.calls == 3
  assert producer.messages[0]["value"]["reason"] == "embedding retries exhausted"
  assert not store.documents


def test_embedding_failure_dead_letter_payload_is_redacted(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, _, producer = build_processor(validator, FailingEmbedder(3))
  processor.process_payload(events["evt-0002"])
  payload_json = json.dumps(producer.messages[0]["value"]["payload"])
  assert SECRET not in payload_json
  assert "[REDACTED]" in payload_json


def test_poison_messages_do_not_block_following_payloads(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  invalid = dict(events["evt-0001"])
  invalid["evidence"] = [{"type": "log", "system": "grafana", "url": "ftp://bad.example/bad"}]
  processor, store, producer = build_processor(validator)
  result = processor.process_messages([invalid, events["evt-0003"]])
  assert result.dead_lettered == 1
  assert result.indexed == 1
  assert len(store.documents) == 1
  assert producer.messages


def test_deterministic_document_id_matches_contract(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  created = validator.parse(events["evt-0006"])
  resolved = validator.parse(events["evt-0017"])
  # tenant + environment + document type + source identity (the incident ID here).
  expected = hashlib.sha256(b"trading|production|incident|INC-0042").hexdigest()[:24]
  assert deterministic_document_id(created, "incident") == expected
  assert deterministic_document_id(resolved, "incident") == expected


def test_log_events_with_same_template_aggregate(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_messages(events[event_id] for event_id in ("evt-0002", "evt-0010", "evt-0011"))
  (document,) = store.of_type("log_template")
  assert document["template"] == "Database connection acquisition timeout exceeded <duration>."
  assert document["occurrences"] == 3
  assert document["first_seen"] == "2026-07-01T10:00:00Z"
  assert document["last_seen"] == "2026-07-01T10:04:00Z"
  assert "3 occurrences" in document["summary"]


def test_timeouts_with_different_templates_are_not_merged(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_messages([events["evt-0002"], events["evt-0016"]])
  templates = sorted(document["template"] for document in store.of_type("log_template"))
  assert templates == [
    "Database connection acquisition timeout exceeded <duration>.",
    "Downstream call to reference-data-service timed out after <duration>.",
  ]


def test_incident_lifecycle_merges_resolution(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_messages([events["evt-0017"], events["evt-0006"]])
  (incident,) = store.of_type("incident")
  assert incident["status"] == "resolved"
  assert incident["cause"] == "database connection pool exhaustion"
  assert incident["resolution"] == "restore previous pool configuration"
  assert incident["symptoms"] == ["HTTP 503", "latency"]
  assert incident["services"] == ["risk-service", "trade-api"]
  assert incident["summary"].startswith(events["evt-0006"]["summary"])


def test_differently_worded_alerts_with_same_name_merge(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  processor, store, _ = build_processor(validator)
  processor.process_messages(events[event_id] for event_id in ("evt-0005", "evt-0013", "evt-0014"))
  alerts = {document["alert_name"]: document for document in store.of_type("alert")}
  assert set(alerts) == {"TradeApiHighErrorRate", "RiskDbPoolSaturated"}
  trade_api = alerts["TradeApiHighErrorRate"]
  assert trade_api["occurrences"] == 2
  assert events["evt-0005"]["summary"] in trade_api["semantic_text"]
  assert events["evt-0013"]["summary"] in trade_api["semantic_text"]


def test_same_alert_name_in_another_tenant_stays_separate(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  other_tenant = copy.deepcopy(events["evt-0005"])
  other_tenant["eventId"] = "evt-9005"
  other_tenant["tenantId"] = "market-data"
  processor, store, _ = build_processor(validator)
  processor.process_messages([events["evt-0005"], other_tenant])
  assert sorted(document["tenant_id"] for document in store.of_type("alert")) == [
    "market-data",
    "trading",
  ]


def test_aggregates_do_not_depend_on_delivery_order(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  ordered = list(events.values())
  shuffled = ordered[:]
  random.Random(7).shuffle(shuffled)
  with_redelivery = shuffled + list(reversed(ordered))

  results = []
  for delivery in (ordered, list(reversed(ordered)), with_redelivery):
    processor, store, producer = build_processor(validator)
    processor.process_messages(copy.deepcopy(delivery))
    assert not producer.messages
    results.append(store.documents)

  assert results[0] == results[1] == results[2]
  assert len(results[0]) == 21
  assert sum(document["occurrences"] for document in results[0].values()) == len(ordered)


def test_write_conflict_is_retried(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  store = InMemoryStore()
  store.injected_conflicts = 2
  processor, _, producer = build_processor(validator, store=store)
  result = processor.process_payload(events["evt-0001"])
  assert result.indexed == 1
  assert not producer.messages


def test_exhausted_write_conflicts_dead_letter_the_event(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  store = InMemoryStore()
  store.injected_conflicts = 3
  processor, _, producer = build_processor(validator, store=store)
  result = processor.process_payload(events["evt-0001"])
  assert result.dead_lettered == 1
  assert producer.messages[0]["value"]["reason"] == "write conflicts exhausted"
