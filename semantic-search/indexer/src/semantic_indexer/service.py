from __future__ import annotations

import logging
import time
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any, Protocol

from semantic_indexer.documents import build_document
from semantic_indexer.embeddings import EmbeddingProvider
from semantic_indexer.metrics import DEAD_LETTER_EVENTS, EMBEDDING_RETRIES, PROCESSED_EVENTS, PROCESSING_LATENCY
from semantic_indexer.redaction import redact_value
from semantic_indexer.validation import EventValidationError, EventValidator

LOGGER = logging.getLogger(__name__)


class DeadLetterProducer(Protocol):
  def send(self, topic: str, value: dict[str, Any], key: str | None = None) -> None: ...


class DocumentWriter(Protocol):
  def write(self, document: Any) -> None: ...


@dataclass
class ProcessorResult:
  indexed: int = 0
  dead_lettered: int = 0


class EventProcessor:
  def __init__(
    self,
    validator: EventValidator,
    embedding_provider: EmbeddingProvider,
    writer: DocumentWriter,
    dead_letter_producer: DeadLetterProducer,
    dead_letter_topic: str,
    max_embedding_retries: int
  ) -> None:
    self._validator = validator
    self._embedding_provider = embedding_provider
    self._writer = writer
    self._dead_letter_producer = dead_letter_producer
    self._dead_letter_topic = dead_letter_topic
    self._max_embedding_retries = max_embedding_retries

  def process_payload(self, payload: dict[str, Any]) -> ProcessorResult:
    with PROCESSING_LATENCY.time():
      return self._process_payload(payload)

  def _process_payload(self, payload: dict[str, Any]) -> ProcessorResult:
    try:
      event = self._validator.parse(payload)
    except (EventValidationError, ValueError) as exc:
      self._publish_dead_letter(payload, str(exc))
      return ProcessorResult(dead_lettered=1)

    event.attributes = redact_value(event.attributes)
    vector = self._embed_with_retries(event)
    if vector is None:
      redacted_payload = dict(payload)
      redacted_payload["attributes"] = event.attributes
      self._publish_dead_letter(redacted_payload, "embedding retries exhausted")
      return ProcessorResult(dead_lettered=1)

    document = build_document(event, vector)
    self._writer.write(document)
    PROCESSED_EVENTS.inc()
    return ProcessorResult(indexed=1)

  def process_messages(self, payloads: Iterable[dict[str, Any]]) -> ProcessorResult:
    total = ProcessorResult()
    for payload in payloads:
      result = self.process_payload(payload)
      total.indexed += result.indexed
      total.dead_lettered += result.dead_lettered
    return total

  def _embed_with_retries(self, event: Any) -> list[float] | None:
    semantic_text = build_document(event, [0.0] * 16).semantic_text
    for attempt in range(1, self._max_embedding_retries + 1):
      try:
        return self._embedding_provider.embed(semantic_text)
      except Exception as exc:  # noqa: BLE001
        LOGGER.warning("embedding failed on attempt %s: %s", attempt, exc)
        EMBEDDING_RETRIES.inc()
        time.sleep(min(attempt, 3))
    return None

  def _publish_dead_letter(self, payload: dict[str, Any], reason: str) -> None:
    DEAD_LETTER_EVENTS.inc()
    self._dead_letter_producer.send(
      self._dead_letter_topic,
      {"reason": reason, "payload": payload},
      key=payload.get("tenantId") or payload.get("eventId")
    )
