from __future__ import annotations

import json
from pathlib import Path

from kafka import KafkaProducer  # type: ignore[attr-defined]

FIXTURE_PATH = Path(__file__).resolve().parents[2] / "fixtures" / "seed-events.jsonl"


def main() -> None:
  producer = KafkaProducer(
    bootstrap_servers="localhost:9092",
    value_serializer=lambda value: json.dumps(value).encode("utf-8")
  )
  for line in FIXTURE_PATH.read_text(encoding="utf-8").splitlines():
    if not line.strip():
      continue
    payload = json.loads(line)
    producer.send(
      "platform.telemetry-events",
      key=payload["eventId"].encode("utf-8"),
      value=payload,
    )
  producer.flush()


if __name__ == "__main__":
  main()
