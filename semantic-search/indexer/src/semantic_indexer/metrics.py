from prometheus_client import Counter, Histogram

PROCESSED_EVENTS = Counter("semantic_indexer_processed_events_total", "Processed events")
DEAD_LETTER_EVENTS = Counter("semantic_indexer_dead_letter_events_total", "Dead-letter events")
EMBEDDING_RETRIES = Counter("semantic_indexer_embedding_retries_total", "Embedding retries")
PROCESSING_LATENCY = Histogram("semantic_indexer_processing_seconds", "Processing latency")
