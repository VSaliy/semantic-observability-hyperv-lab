from semantic_indexer.config import IndexerSettings
from semantic_indexer.runtime import KafkaEventRuntime


def main() -> None:
  KafkaEventRuntime(IndexerSettings()).run_forever()


if __name__ == "__main__":
  main()
