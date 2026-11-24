# ruff: noqa: F811
from __future__ import annotations

import json
import time
from typing import Any

import pytest

from semantic_indexer.redaction import (
  REDACTED,
  URL_REDACTED,
  is_sensitive_key,
  redact_evidence_url,
  redact_text,
  redact_value,
)
from semantic_indexer.validation import EventValidationError, EventValidator
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


def test_redact_evidence_url_preserves_safe_params_and_redacts_secrets() -> None:
  secret_param = "=".join(("token", "hunter2secret"))
  api_param = "=".join(("api_" + "key", "sk-live-" + "0" * 6))
  raw_url = (
    f"https://grafana.example/d/chg-0184"
    f"?orgId=1&{secret_param}&user=jane.doe@example.com&{api_param}#section"
  )
  redacted = redact_evidence_url(raw_url)
  assert redacted == (
    f"https://grafana.example/d/chg-0184"
    f"?orgId=1&token={URL_REDACTED}&user={URL_REDACTED}&api_key={URL_REDACTED}#section"
  )
  assert "[" not in redacted and "]" not in redacted


def test_evidence_urls_are_redacted_before_indexing_and_dead_lettering(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  event = dict(events["evt-0001"])
  secret_param = "=".join(("token", "supersecret99"))
  event["evidence"] = [
    {
      "type": "deployment",
      "system": "grafana",
      "url": f"https://grafana.example/d/chg-0184?orgId=1&{secret_param}&contact=ops@example.com"
    }
  ]
  processor, store, _ = build_processor(validator)
  processor.process_payload(event)
  stored = json.dumps(store.documents)
  assert "supersecret99" not in stored
  assert "ops@example.com" not in stored
  assert "https://grafana.example/d/chg-0184?orgId=1&token=REDACTED&contact=REDACTED" in stored

  failing_processor, _, producer = build_processor(validator, FailingEmbedder(3))
  failing_processor.process_payload(event)
  dead_letter = json.dumps(producer.messages[0]["value"])
  assert "supersecret99" not in dead_letter
  assert "ops@example.com" not in dead_letter


def test_email_pattern_bounded_and_requires_alpha_tld() -> None:
  assert redact_text("running trade-api@2.4.1 in prod") == "running trade-api@2.4.1 in prod"
  assert redact_text("mail jane.doe@example.com") == f"mail {REDACTED}"


def test_assignment_pattern_distinguishes_secrets_from_prose() -> None:
  assert (
    redact_text("refresh token: connection refused")
    == "refresh token: connection refused"
  )
  assert "hunter2abc" not in redact_text("password=hunter2abc")
  assert REDACTED in redact_text("password=hunter2abc")
  jwt_sample = ": ".join(("token", "eyJhbGciOiJIUzI1NiJ9"))  # gitleaks:allow
  assert "eyJhbGciOi" not in redact_text(jwt_sample)
  assert REDACTED in redact_text(jwt_sample)
  api_key_sample = ": ".join(("api_key", "sk-live-000000"))  # gitleaks:allow
  assert "sk-live-000000" not in redact_text(api_key_sample)
  assert REDACTED in redact_text(api_key_sample)


@pytest.mark.parametrize(
  ("key", "expected"),
  [
    ("db.connection.state", False),
    ("tokens_used", False),
    ("token_count", False),
    ("password", True),
    ("client_secret", True),
    ("access_token", True),
    ("connection_string", True),
    ("db.connectionString", True),
    ("Authorization", True),
    ("set-cookie", True),
  ],
)
def test_sensitive_key_segment_matching(key: str, expected: bool) -> None:
  assert is_sensitive_key(key) is expected


def test_redact_evidence_url_strips_userinfo() -> None:
  assert (
    redact_evidence_url("https://user:pass@grafana.example/d/1")
    == "https://grafana.example/d/1"
  )


def test_adversarial_redos_performance() -> None:
  adversarial = "a" * 50000 + "@"
  start = time.perf_counter()
  res = redact_text(adversarial)
  elapsed = time.perf_counter() - start
  assert res == adversarial
  assert elapsed < 0.2


def test_free_text_length_caps_at_validation(
  events: dict[str, dict[str, Any]], validator: EventValidator
) -> None:
  event = dict(events["evt-0001"])
  oversized_summary = dict(event)
  oversized_summary["summary"] = "x" * 4097
  with pytest.raises((EventValidationError, ValueError)):
    validator.parse(oversized_summary)

  oversized_attribute = dict(event)
  oversized_attribute["attributes"] = {"note": "x" * 8193}
  with pytest.raises((EventValidationError, ValueError)):
    validator.parse(oversized_attribute)