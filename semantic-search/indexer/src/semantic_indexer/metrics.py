from prometheus_client import Counter, Histogram

PROCESSED_EVENTS = Counter("semantic_indexer_processed_events_total", "Processed events")
DEAD_LETTER_EVENTS = Counter("semantic_indexer_dead_letter_events_total", "Dead-letter events")
EMBEDDING_RETRIES = Counter("semantic_indexer_embedding_retries_total", "Embedding retries")
DUPLICATE_EVENTS = Counter(
  "semantic_indexer_duplicate_events_total", "Redelivered events already in their aggregate"
)
WRITE_CONFLICTS = Counter(
  "semantic_indexer_write_conflicts_total", "Optimistic-concurrency conflicts on aggregate writes"
)
PROCESSING_LATENCY = Histogram("semantic_indexer_processing_seconds", "Processing latency")
