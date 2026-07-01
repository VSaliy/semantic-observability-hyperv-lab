from __future__ import annotations

import json
import logging
import time

from kafka import KafkaConsumer, KafkaProducer  # type: ignore[attr-defined]
from prometheus_client import start_http_server

from semantic_indexer.config import IndexerSettings
from semantic_indexer.embeddings import HttpEmbeddingProvider
from semantic_indexer.opensearch_io import OpenSearchWriter
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


class KafkaEventRuntime:
  def __init__(self, settings: IndexerSettings) -> None:
    self._settings = settings
    validator = EventValidator(settings.schema_path, settings.valid_evidence_hosts)
    producer = KafkaProducer(
      bootstrap_servers=settings.kafka_bootstrap_servers,
      value_serializer=lambda value: json.dumps(value).encode("utf-8")
    )
    self._processor = EventProcessor(
      validator=validator,
      embedding_provider=HttpEmbeddingProvider(
        settings.embedding_url,
        settings.embedding_timeout_seconds
      ),
      writer=OpenSearchWriter(settings.opensearch_url, settings.opensearch_index_alias),
      dead_letter_producer=JsonDeadLetterProducer(producer),
      dead_letter_topic=settings.kafka_dead_letter_topic,
      max_embedding_retries=settings.max_embedding_retries
    )
    self._consumer = KafkaConsumer(
      settings.kafka_topic,
      bootstrap_servers=settings.kafka_bootstrap_servers,
      group_id=settings.kafka_group_id,
      auto_offset_reset="earliest",
      enable_auto_commit=True,
      value_deserializer=lambda value: json.loads(value.decode("utf-8")),
      consumer_timeout_ms=int(settings.poll_timeout_seconds * 1000)
    )

  def run_forever(self) -> None:
    if self._settings.enable_metrics_server:
      start_http_server(self._settings.metrics_port)
    while True:
      processed = False
      for message in self._consumer:
        processed = True
        self._processor.process_payload(message.value)
      if not processed:
        LOGGER.info("no events available, sleeping")
        time.sleep(self._settings.startup_backoff_seconds)
