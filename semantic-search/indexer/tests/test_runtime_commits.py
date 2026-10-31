from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import pytest
from kafka import OffsetAndMetadata, TopicPartition  # type: ignore[attr-defined]

from semantic_indexer.runtime import consume_available
from semantic_indexer.validation import EventValidator
from test_event_processor import SCHEMA_PATH, build_processor

TOPIC = "platform.telemetry-events"


class FakeConsumer:
  def __init__(self, messages: list[Any]) -> None:
    self._messages = messages
    self.commits: list[dict[Any, Any]] = []

  def __iter__(self) -> Any:
    return iter(self._messages)

  def commit(self, offsets: dict[Any, Any] | None = None) -> None:
    assert offsets is not None
    self.commits.append(offsets)


class RecordingProcessor:
  def __init__(self, fail_on: str | None = None) -> None:
    self.processed: list[str] = []
    self._fail_on = fail_on

  def process_payload(self, payload: dict[str, Any]) -> None:
    if payload["id"] == self._fail_on:
      raise ConnectionError("opensearch unreachable")
    self.processed.append(payload["id"])

  def dead_letter_undecodable(self, raw: bytes, reason: str, origin: str) -> None:
    raise AssertionError("not expected")


def message(partition: int, offset: int, value: dict[str, Any]) -> Any:
  return SimpleNamespace(topic=TOPIC, partition=partition, offset=offset, value=value)


def committed(consumer: FakeConsumer) -> list[tuple[int, int]]:
  return [(tp.partition, meta.offset) for commit in consumer.commits for tp, meta in commit.items()]


def test_offsets_are_committed_after_success_as_offset_plus_one() -> None:
  consumer = FakeConsumer(
    [message(0, 7, {"id": "a"}), message(1, 3, {"id": "b"}), message(0, 8, {"id": "c"})]
  )
  processor = RecordingProcessor()
  assert consume_available(consumer, consumer, processor) == 3
  assert processor.processed == ["a", "b", "c"]
  assert committed(consumer) == [(0, 8), (1, 4), (0, 9)]
  assert consumer.commits[0] == {TopicPartition(TOPIC, 0): OffsetAndMetadata(8, "", -1)}


def test_nothing_is_committed_when_processing_raises() -> None:
  consumer = FakeConsumer([message(0, 1, {"id": "boom"}), message(0, 2, {"id": "later"})])
  processor = RecordingProcessor(fail_on="boom")
  with pytest.raises(ConnectionError):
    consume_available(consumer, consumer, processor)
  assert consumer.commits == []
  assert processor.processed == []


def test_commit_stops_at_the_failing_message() -> None:
  consumer = FakeConsumer(
    [message(0, 1, {"id": "a"}), message(0, 2, {"id": "boom"}), message(0, 3, {"id": "c"})]
  )
  with pytest.raises(ConnectionError):
    consume_available(consumer, consumer, RecordingProcessor(fail_on="boom"))
  assert committed(consumer) == [(0, 2)]


def test_dead_lettered_event_is_committed() -> None:
  validator = EventValidator(str(SCHEMA_PATH), ["grafana.example"])
  processor, store, producer = build_processor(validator)
  consumer = FakeConsumer([message(2, 41, {"eventId": "not-a-valid-event"})])
  assert consume_available(consumer, consumer, processor) == 1
  assert len(producer.messages) == 1
  assert store.documents == {}
  assert committed(consumer) == [(2, 42)]
