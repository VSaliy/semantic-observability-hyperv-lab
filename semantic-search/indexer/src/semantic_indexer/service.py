from __future__ import annotations

import hashlib
import logging
import time
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any, Protocol

from semantic_indexer.documents import (
  aggregate_document,
  build_contribution,
  deterministic_document_id,
  document_type_for,
)
from semantic_indexer.embeddings import EmbeddingProvider
from semantic_indexer.metrics import (
  DEAD_LETTER_EVENTS,
  DUPLICATE_EVENTS,
  EMBEDDING_RETRIES,
  PROCESSED_EVENTS,
  PROCESSING_LATENCY,
  WRITE_CONFLICTS,
)
from semantic_indexer.models import SemanticDocument
from semantic_indexer.redaction import redact_text, redact_value
from semantic_indexer.validation import EventValidationError, EventValidator

LOGGER = logging.getLogger(__name__)


class DeadLetterProducer(Protocol):
  def send(self, topic: str, value: dict[str, Any], key: str | None = None) -> None: ...


@dataclass(frozen=True)
class StoredDocument:
  document: SemanticDocument
  version: object


class DocumentStore(Protocol):
  def get(self, document_id: str) -> StoredDocument | None: ...

  def put(self, document: SemanticDocument, expected: StoredDocument | None) -> bool:
    """Write if the stored version still matches `expected`; return False on a conflict."""
    ...


@dataclass
class ProcessorResult:
  indexed: int = 0
  duplicates: int = 0
  dead_lettered: int = 0


class EventProcessor:
  def __init__(
    self,
    validator: EventValidator,
    embedding_provider: EmbeddingProvider,
    store: DocumentStore,
    dead_letter_producer: DeadLetterProducer,
    dead_letter_topic: str,
    max_embedding_retries: int,
    max_write_attempts: int = 3
  ) -> None:
    self._validator = validator
    self._embedding_provider = embedding_provider
    self._store = store
    self._dead_letter_producer = dead_letter_producer
    self._dead_letter_topic = dead_letter_topic
    self._max_embedding_retries = max_embedding_retries
    self._max_write_attempts = max_write_attempts

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
    event.summary = redact_text(event.summary)
    redacted_payload = dict(payload)
    redacted_payload["attributes"] = event.attributes
    redacted_payload["summary"] = event.summary
    contribution = build_contribution(event)
    document_type = document_type_for(event)
    document_id = deterministic_document_id(event, document_type)

    for _ in range(self._max_write_attempts):
      stored = self._store.get(document_id)
      existing = stored.document.contributions if stored else []
      if any(item.event_id == event.eventId for item in existing):
        DUPLICATE_EVENTS.inc()
        return ProcessorResult(duplicates=1)
      document = aggregate_document(
        document_id, document_type, event.tenantId, event.environment, [*existing, contribution]
      )
      vector = self._embed_with_retries(document.semantic_text)
      if vector is None:
        self._publish_dead_letter(redacted_payload, "embedding retries exhausted")
        return ProcessorResult(dead_lettered=1)
      document.semantic_vector = vector
      if self._store.put(document, stored):
        PROCESSED_EVENTS.inc()
        return ProcessorResult(indexed=1)
      WRITE_CONFLICTS.inc()
      LOGGER.info("write conflict on %s, retrying", document_id)

    self._publish_dead_letter(redacted_payload, "write conflicts exhausted")
    return ProcessorResult(dead_lettered=1)

  def process_messages(self, payloads: Iterable[dict[str, Any]]) -> ProcessorResult:
    total = ProcessorResult()
    for payload in payloads:
      result = self.process_payload(payload)
      total.indexed += result.indexed
      total.duplicates += result.duplicates
      total.dead_lettered += result.dead_lettered
    return total

  def _embed_with_retries(self, semantic_text: str) -> list[float] | None:
    for attempt in range(1, self._max_embedding_retries + 1):
      try:
        return self._embedding_provider.embed(semantic_text)
      except Exception as exc:  # noqa: BLE001
        LOGGER.warning("embedding failed on attempt %s: %s", attempt, exc)
        EMBEDDING_RETRIES.inc()
        time.sleep(min(attempt, 3))
    return None

  def dead_letter_undecodable(self, raw: bytes, reason: str, origin: str) -> None:
    """Dead-letter a message that is not a JSON object, without copying its content.

    Only size, digest and origin are kept: undecodable bytes cannot be redacted.
    """
    DEAD_LETTER_EVENTS.inc()
    self._dead_letter_producer.send(
      self._dead_letter_topic,
      {
        "reason": reason,
        "payload": None,
        "raw": {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(), "origin": origin}
      }
    )

  def _publish_dead_letter(self, payload: dict[str, Any], reason: str) -> None:
    DEAD_LETTER_EVENTS.inc()
    self._dead_letter_producer.send(
      self._dead_letter_topic,
      {"reason": reason, "payload": redact_value(payload)},
      key=payload.get("tenantId") or payload.get("eventId")
    )
