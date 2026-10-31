from __future__ import annotations

import json
import logging
import time
from collections.abc import Iterable
from typing import Any, Protocol

from kafka import (  # type: ignore[attr-defined]
  KafkaConsumer,
  KafkaProducer,
  OffsetAndMetadata,
  TopicPartition,
)
from prometheus_client import start_http_server

from semantic_indexer.config import IndexerSettings
from semantic_indexer.embeddings import CachingEmbeddingProvider, HttpEmbeddingProvider
from semantic_indexer.opensearch_io import OpenSearchDocumentStore
from semantic_indexer.service import EventProcessor
from semantic_indexer.validation import EventValidator

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
LOGGER = logging.getLogger(__name__)


class JsonDeadLetterProducer:
  def __init__(self, producer: KafkaProducer) -> None:
    self._producer = producer

  def send(self, topic: str, value: dict[str, object], key: str | None = None) -> None:
    encoded_key = key.encode("utf-8") if key else None
    self._producer.send(topic, key=encoded_key, value=value)
    self._producer.flush()


class OffsetCommittingConsumer(Protocol):
  """The slice of KafkaConsumer the runtime needs; tests inject a fake."""

  def __iter__(self) -> Any: ...

  def commit(self, offsets: dict[Any, Any] | None = None) -> None: ...


class PayloadProcessor(Protocol):
  def process_payload(self, payload: dict[str, Any]) -> object: ...

  def dead_letter_undecodable(self, raw: bytes, reason: str, origin: str) -> None: ...


def decode_message(value: Any) -> dict[str, Any] | None:
  """Return the JSON object carried by a message, or None if it is not one."""
  if isinstance(value, dict):
    return value
  try:
    decoded = json.loads(value.decode("utf-8") if isinstance(value, bytes) else value)
  except (ValueError, TypeError):
    return None
  return decoded if isinstance(decoded, dict) else None


def consume_available(consumer: Iterable[Any], committer: OffsetCommittingConsumer,
                      processor: PayloadProcessor) -> int:
  """Handle every message the consumer yields and commit each offset only after it is handled.

  process_payload returns for indexed, duplicate and dead-lettered events (the dead letter is
  flushed before it returns), so all three are committed. Messages that are not JSON objects are
  dead-lettered as well, so one poison message cannot block its partition. If processing raises,
  the exception propagates without committing: the process must stop so the message is
  redelivered after a restart. Delivery is therefore at-least-once; the idempotent aggregates
  absorb the redelivery.
  """
  handled = 0
  for message in consumer:
    payload = decode_message(message.value)
    if payload is None:
      raw = message.value if isinstance(message.value, bytes) else str(message.value).encode()
      processor.dead_letter_undecodable(
        raw,
        "message is not a JSON object",
        f"{message.topic}[{message.partition}]@{message.offset}"
      )
    else:
      processor.process_payload(payload)
    partition = TopicPartition(message.topic, message.partition)
    committer.commit({partition: OffsetAndMetadata(message.offset + 1, "", -1)})
    handled += 1
  return handled


class KafkaEventRuntime:
  def __init__(
    self,
    settings: IndexerSettings,
    processor: PayloadProcessor | None = None,
    consumer: OffsetCommittingConsumer | None = None
  ) -> None:
    self._settings = settings
    self._processor = processor or self._build_processor(settings)
    self._consumer = consumer or KafkaConsumer(
      settings.kafka_topic,
      bootstrap_servers=settings.kafka_bootstrap_servers,
      group_id=settings.kafka_group_id,
      auto_offset_reset="earliest",
      enable_auto_commit=False,
      value_deserializer=None,
      consumer_timeout_ms=int(settings.poll_timeout_seconds * 1000)
    )

  @staticmethod
  def _build_processor(settings: IndexerSettings) -> EventProcessor:
    validator = EventValidator(settings.schema_path, settings.valid_evidence_hosts)
    producer = KafkaProducer(
      bootstrap_servers=settings.kafka_bootstrap_servers,
      value_serializer=lambda value: json.dumps(value).encode("utf-8")
    )
    return EventProcessor(
      validator=validator,
      embedding_provider=CachingEmbeddingProvider(
        HttpEmbeddingProvider(settings.embedding_url, settings.embedding_timeout_seconds)
      ),
      store=OpenSearchDocumentStore(settings.opensearch_url, settings.opensearch_index_alias),
      dead_letter_producer=JsonDeadLetterProducer(producer),
      dead_letter_topic=settings.kafka_dead_letter_topic,
      max_embedding_retries=settings.max_embedding_retries
    )

  def run_forever(self) -> None:
    if self._settings.enable_metrics_server:
      start_http_server(self._settings.metrics_port)
    while True:
      if consume_available(self._consumer, self._consumer, self._processor) == 0:
        LOGGER.info("no events available, sleeping")
        time.sleep(self._settings.startup_backoff_seconds)