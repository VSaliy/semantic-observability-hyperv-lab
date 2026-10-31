# ruff: noqa: F811
from __future__ import annotations

import json
from typing import Any

import pytest

from semantic_indexer.redaction import REDACTED, redact_text, redact_value
from semantic_indexer.validation import EventValidator
from test_event_processor import (  # noqa: F401
  FailingEmbedder,
  RecordingEmbedder,
  build_processor,
  events,
  no_retry_sleep,
  validator,
)

JWT = ".".join(("eyJhbGciOiJIUzI1NiJ9", "eyJ0ZW5hbnQiOiJ0cmFkaW5nIn0", "c2lnbmF0dXJlMTIzNDU2"))
SENSITIVE = [
  "contact jane.doe@example.com for access",
  " ".join(("retry with Bearer", "abcdef1234567890XYZ")),
  f"token leaked {JWT}",
  "key AKIA" + "IOSFODNN7EXAMPLE in config",
  "=".join(("password", "hunter2hunter2 in url")),
  "api_" + "key: " + "sk-live-" + "0" * 6,  # gitleaks:allow
  "ghp_" + "a" * 36,
  " ".join(("-----BEGIN", "RSA PRIVATE KEY-----\nMIIEvQIBADANBgkq")),
]
BENIGN = [
  "Connection pool exhausted after deploy 2026.06.2",
  "Order gateway timeout while calling pricing-service at 0.42 ratio",
  "trace 4bf92f3577b34da6a3ce929d0e0e4736 failed",
]


@pytest.mark.parametrize("text", SENSITIVE)
def test_sensitive_value_patterns_are_redacted(text: str) -> None:
  redacted = redact_text(text)
  assert REDACTED in redacted
  needles = ("jane.doe", "abcdef1234567890", "AKIAIOSFODNN7", "hunter2", "sk-live", "MIIEvQ")
  for needle in (*needles, "c2lnbmF0"):
    assert needle not in redacted


@pytest.mark.parametrize("text", BENIGN)
def test_ordinary_text_is_unchanged(text: str) -> None:
  assert redact_text(text) == text


def test_redact_value_scans_nested_values_under_innocuous_keys() -> None:
  value = {"note": "mail ops@example.com", "list": ["Bearer abcdef1234567890"], "n": 5}
  redacted = redact_value(value)
  assert "ops@example.com" not in json.dumps(redacted)
  assert "abcdef1234567890" not in json.dumps(redacted)
  assert redacted["n"] == 5


def test_summary_and_attributes_are_redacted_before_index_and_embedding(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  event = dict(events["evt-0001"])
  event["summary"] = "Login failed for jane.doe@example.com password=hunter2hunter2"
  event["attributes"] = {**event.get("attributes", {}), "note": "ping ops@example.com"}
  embedder = RecordingEmbedder()
  processor, store, _ = build_processor(validator, embedder)
  processor.process_payload(event)
  stored = json.dumps(store.documents)
  for needle in ("jane.doe@example.com", "hunter2", "ops@example.com"):
    assert needle not in stored
    assert all(needle not in text for text in embedder.texts)
  assert embedder.texts


def test_dead_letter_summary_is_redacted(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  event = dict(events["evt-0001"])
  event["summary"] = "mail jane.doe@example.com"
  processor, _, producer = build_processor(validator, FailingEmbedder(3))
  processor.process_payload(event)
  assert "jane.doe" not in json.dumps(producer.messages[0]["value"])