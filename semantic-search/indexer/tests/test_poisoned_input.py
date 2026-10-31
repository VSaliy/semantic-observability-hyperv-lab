from __future__ import annotations

import hashlib
import json
from types import SimpleNamespace
from typing import Any

import pytest
from kafka import OffsetAndMetadata, TopicPartition  # type: ignore[attr-defined]

from semantic_indexer.runtime import consume_available, decode_message
from semantic_indexer.validation import EventValidationError, EventValidator
from test_event_processor import FIXTURE_PATH, SCHEMA_PATH, build_processor
from test_runtime_commits import FakeConsumer

TOPIC = "platform.telemetry-events"
ALLOWED = ["grafana.example", "kafka.example", "opensearch.example"]


@pytest.fixture()
def validator() -> EventValidator:
  return EventValidator(str(SCHEMA_PATH), ALLOWED)


@pytest.fixture()
def event() -> dict[str, Any]:
  return dict(json.loads(FIXTURE_PATH.read_text(encoding="utf-8").splitlines()[0]))


def with_url(event: dict[str, Any], url: str) -> dict[str, Any]:
  payload = dict(event)
  payload["evidence"] = [{"type": "log", "system": "grafana", "url": url}]
  return payload


@pytest.mark.parametrize(
  "url",
  [
    "javascript:alert(1)",
    "ftp://grafana.example/x",
    "file:///etc/passwd",
    "//grafana.example/x",
    "https://grafana.example.evil.test/x",
    "https://evil.test/grafana.example",
    "https://grafana.example@evil.test/x",
    "https://evil.test@grafana.example/x",
    "https://grafana.example:8443/x",
    "https://GRAFANA.example/x",
    "https://grafana.example.:443/x",
  ],
)
def test_evidence_urls_outside_the_allowlist_are_rejected(
  validator: EventValidator, event: dict[str, Any], url: str
) -> None:
  with pytest.raises((EventValidationError, ValueError)):
    validator.parse(with_url(event, url))


def test_allowlisted_evidence_url_is_accepted(
  validator: EventValidator, event: dict[str, Any]
) -> None:
  validator.parse(with_url(event, "https://grafana.example/d/abc?x=1"))


def test_validation_failure_dead_letter_is_redacted(
  validator: EventValidator, event: dict[str, Any]
) -> None:
  payload = dict(event)
  payload["attributes"] = {"apiToken": "s3cr3t", "nested": {"password": "hunter2"}, "ok": "fine"}
  payload["evidence"] = [{"type": "log", "system": "grafana", "url": "ftp://evil.test/x"}]
  processor, _, producer = build_processor(validator)
  assert processor.process_payload(payload).dead_lettered == 1
  sent = json.dumps(producer.messages[0]["value"])
  assert "s3cr3t" not in sent
  assert "hunter2" not in sent
  assert "fine" in sent


def raw_message(offset: int, value: Any) -> Any:
  return SimpleNamespace(topic=TOPIC, partition=0, offset=offset, value=value)


@pytest.mark.parametrize("raw", [b"not json", b"\xff\xfe", b"[1, 2]", b'"text"', b"null", b""])
def test_non_object_messages_are_not_decoded(raw: bytes) -> None:
  assert decode_message(raw) is None


def test_undecodable_message_is_dead_lettered_without_content_and_committed(
  validator: EventValidator,
) -> None:
  processor, store, producer = build_processor(validator)
  raw = b"password=hunter2 \xff"
  consumer = FakeConsumer([raw_message(5, raw)])
  assert consume_available(consumer, consumer, processor) == 1
  assert store.documents == {}
  sent = producer.messages[0]["value"]
  assert sent["payload"] is None
  assert sent["raw"] == {
    "bytes": len(raw),
    "sha256": hashlib.sha256(raw).hexdigest(),
    "origin": f"{TOPIC}[0]@5",
  }
  assert "hunter2" not in json.dumps(sent)
  assert consumer.commits == [{TopicPartition(TOPIC, 0): OffsetAndMetadata(6, "", -1)}]


def test_poison_message_does_not_block_following_events(
  validator: EventValidator, event: dict[str, Any]
) -> None:
  processor, store, producer = build_processor(validator)
  consumer = FakeConsumer(
    [raw_message(1, b"garbage"), raw_message(2, json.dumps(event).encode("utf-8"))]
  )
  assert consume_available(consumer, consumer, processor) == 2
  assert len(store.documents) == 1
  assert len(producer.messages) == 1
  assert [meta.offset for c in consumer.commits for meta in c.values()] == [2, 3]
