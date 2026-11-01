from __future__ import annotations

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class IndexerSettings(BaseSettings):
  model_config = SettingsConfigDict(env_prefix="INDEXER_", case_sensitive=False)

  kafka_bootstrap_servers: str = "kafka:9092"
  kafka_topic: str = "platform.telemetry-events"
  kafka_dead_letter_topic: str = "semantic.dead-letter"
  kafka_group_id: str = "semantic-indexer"
  opensearch_url: str = "http://opensearch:9200"
  opensearch_index_alias: str = "observability-documents"
  embedding_url: str = "http://embedding-service:8090/embed"
  embedding_timeout_seconds: float = 5.0
  max_embedding_retries: int = 3
  metrics_port: int = 9108
  poll_timeout_seconds: float = 1.0
  startup_backoff_seconds: float = 2.0
  enable_metrics_server: bool = True
  max_contributions_per_aggregate: int = 100
  max_tracked_event_ids_per_aggregate: int = 1000
  schema_path: str = "/app/schemas/operational-event.schema.json"
  valid_evidence_hosts: list[str] = Field(
    default_factory=lambda: ["grafana.example", "kafka.example", "opensearch.example"]
  )
  tenant_valid_evidence_hosts: dict[str, list[str]] = Field(
    default_factory=lambda: {
      "trading": ["grafana.example", "kafka.example", "opensearch.example"],
      "market-data": ["grafana.example", "opensearch.example"],
      "payments": ["grafana.example", "opensearch.example"],
    }
  )

  @model_validator(mode="after")
  def validate_aggregate_bounds(self) -> IndexerSettings:
    if self.max_contributions_per_aggregate < 1:
      raise ValueError("max_contributions_per_aggregate must be at least 1")
    if self.max_tracked_event_ids_per_aggregate < self.max_contributions_per_aggregate:
      raise ValueError(
        "max_tracked_event_ids_per_aggregate must be at least max_contributions_per_aggregate"
      )
    return self
