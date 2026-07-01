from pydantic import Field
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
  schema_path: str = "/app/schemas/operational-event.schema.json"
  valid_evidence_hosts: list[str] = Field(
    default_factory=lambda: ["grafana.example", "kafka.example", "opensearch.example"]
  )
