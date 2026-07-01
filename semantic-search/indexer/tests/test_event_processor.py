from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from semantic_indexer.documents import deterministic_document_id
from semantic_indexer.embeddings import DeterministicEmbeddingProvider
from semantic_indexer.service import EventProcessor
from semantic_indexer.validation import EventValidator

FIXTURE_PATH = Path(__file__).resolve().parents[1] / "fixtures" / "seed-events.jsonl"
SCHEMA_PATH = Path(__file__).resolve().parents[2] / "schemas" / "operational-event.schema.json"


class InMemoryWriter:
  def __init__(self) -> None:
    self.documents: dict[str, dict[str, Any]] = {}

  def write(self, document: Any) -> None:
    self.documents[document.document_id] = document.model_dump(mode="json")


class InMemoryProducer:
  def __init__(self) -> None:
    self.messages: list[dict[str, Any]] = []

  def send(self, topic: str, value: dict[str, Any], key: str | None = None) -> None:
    self.messages.append({"topic": topic, "value": value, "key": key})


class FailingEmbedder:
  def __init__(self, failures: int) -> None:
    self.failures = failures
    self.calls = 0

  def embed(self, text: str) -> list[float]:
    self.calls += 1
    if self.calls <= self.failures:
      raise RuntimeError("embedding unavailable")
    return [0.1] * 16


@pytest.fixture()
def events() -> list[dict[str, Any]]:
  lines = FIXTURE_PATH.read_text(encoding="utf-8").splitlines()
  return [json.loads(line) for line in lines if line]


@pytest.fixture()
def validator() -> EventValidator:
  allowed = ["grafana.example", "kafka.example", "opensearch.example"]
  return EventValidator(str(SCHEMA_PATH), allowed)


def build_processor(
  validator: EventValidator, embedder: Any | None = None
) -> tuple[EventProcessor, InMemoryWriter, InMemoryProducer]:
  writer = InMemoryWriter()
  producer = InMemoryProducer()
  processor = EventProcessor(
    validator=validator,
    embedding_provider=embedder or DeterministicEmbeddingProvider(),
    writer=writer,
    dead_letter_producer=producer,
    dead_letter_topic="semantic.dead-letter",
    max_embedding_retries=3
  )
  return processor, writer, producer


def test_valid_event_creates_document(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  processor, writer, _ = build_processor(validator)
  result = processor.process_payload(events[0])
  assert result.indexed == 1
  assert len(writer.documents) == 1


def test_invalid_event_reaches_dead_letter_topic(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  invalid = dict(events[0])
  invalid.pop("tenantId")
  processor, _, producer = build_processor(validator)
  result = processor.process_payload(invalid)
  assert result.dead_lettered == 1
  assert producer.messages[0]["topic"] == "semantic.dead-letter"


def test_duplicate_delivery_creates_no_duplicate(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  processor, writer, _ = build_processor(validator)
  processor.process_payload(events[0])
  processor.process_payload(events[0])
  assert len(writer.documents) == 1


def test_redacted_values_never_reach_opensearch(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  processor, writer, _ = build_processor(validator)
  processor.process_payload(events[1])
  document = next(iter(writer.documents.values()))
  assert "jdbc:postgresql://db.internal/trading" not in json.dumps(document)
  assert "[REDACTED]" in document["semantic_text"]


def test_tenant_id_is_mandatory(events: list[dict[str, Any]], validator: EventValidator) -> None:
  invalid = dict(events[0])
  invalid["tenantId"] = ""
  processor, _, producer = build_processor(validator)
  processor.process_payload(invalid)
  assert producer.messages


def test_evidence_references_survive_transformation(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  processor, writer, _ = build_processor(validator)
  processor.process_payload(events[2])
  document = next(iter(writer.documents.values()))
  assert document["source_references"][0]["url"] == events[2]["evidence"][0]["url"]


def test_embedding_failure_uses_bounded_retries(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  processor, _, producer = build_processor(validator, FailingEmbedder(3))
  processor.process_payload(events[0])
  assert producer.messages[0]["value"]["reason"] == "embedding retries exhausted"


def test_poison_messages_do_not_block_following_payloads(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  invalid = dict(events[0])
  invalid["evidence"] = [{"type": "log", "system": "grafana", "url": "ftp://bad.example/bad"}]
  processor, writer, producer = build_processor(validator)
  result = processor.process_messages([invalid, events[2]])
  assert result.dead_lettered == 1
  assert result.indexed == 1
  assert len(writer.documents) == 1
  assert producer.messages


def test_deterministic_document_id_matches_contract(
  events: list[dict[str, Any]], validator: EventValidator
) -> None:
  event = validator.parse(events[5])
  assert deterministic_document_id(event, "incident") == "c5e3f9ebd42b985d32185584"
