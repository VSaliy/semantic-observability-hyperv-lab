from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from semantic_indexer.documents import aggregate_document, normalize_template
from semantic_indexer.embeddings import CachingEmbeddingProvider, DeterministicEmbeddingProvider
from semantic_indexer.models import Contribution


@pytest.mark.parametrize(
  ("message", "template"),
  [
    (
      "Database connection acquisition timeout exceeded 30 seconds.",
      "Database connection acquisition timeout exceeded <duration>.",
    ),
    ("Call timed out after 5000 ms", "Call timed out after <duration>"),
    ("Retry 3 of 5 for order 42", "Retry <num> of <num> for order <num>"),
    ("Peer 10.50.0.12 unreachable via 10.60.0.0/24", "Peer <ip> unreachable via <ip>"),
    (
      "Request 3f2b9c1e-8d4a-4f6b-9a1e-2c3d4e5f6a7b failed",
      "Request <id> failed",
    ),
    ("Checksum 0xdeadbeef mismatch", "Checksum <id> mismatch"),
    ("  extra   whitespace  ", "extra whitespace"),
  ],
)
def test_normalize_template_masks_variable_parts(message: str, template: str) -> None:
  assert normalize_template(message) == template


def test_messages_that_differ_only_in_values_share_a_template() -> None:
  assert normalize_template("Pool wait 30 seconds on instance 1") == normalize_template(
    "Pool wait 31 seconds on instance 2"
  )


class CountingEmbedder(DeterministicEmbeddingProvider):
  def __init__(self, fail: bool = False) -> None:
    self.calls = 0
    self.fail = fail

  def embed(self, text: str) -> list[float]:
    self.calls += 1
    if self.fail:
      raise RuntimeError("unavailable")
    return super().embed(text)


def test_caching_embedder_embeds_repeated_text_once() -> None:
  delegate = CountingEmbedder()
  cache = CachingEmbeddingProvider(delegate)
  first = cache.embed("same text")
  second = cache.embed("same text")
  assert first == second
  assert delegate.calls == 1


def test_caching_embedder_is_bounded() -> None:
  delegate = CountingEmbedder()
  cache = CachingEmbeddingProvider(delegate, max_entries=2)
  for text in ("a", "b", "c", "a"):
    cache.embed(text)
  assert delegate.calls == 4  # "a" was evicted by "c" and embedded again


def test_caching_embedder_does_not_cache_failures() -> None:
  delegate = CountingEmbedder(fail=True)
  cache = CachingEmbeddingProvider(delegate)
  for _ in range(2):
    with pytest.raises(RuntimeError):
      cache.embed("text")
  assert delegate.calls == 2


def test_aggregate_document_caps_contributions_while_preserving_first_and_latest() -> None:
  start = datetime(2026, 7, 1, 10, 0, tzinfo=UTC)
  contributions = [
    Contribution(
      event_id=f"evt-{index:04d}",
      event_type="application.error",
      timestamp=start + timedelta(seconds=index),
      summary=f"Database connection acquisition timeout exceeded {30 + index} seconds.",
      severity="ERROR",
      service_name="trade-api",
      service_namespace="trading",
      service_version="2.4.1",
      template="Database connection acquisition timeout exceeded <duration>.",
      evidence=[]
    )
    for index in range(1, 6)
  ]
  document = aggregate_document(
    "doc-0001",
    "log_template",
    "trading",
    "production",
    contributions,
    max_contributions=3,
    prior_occurrences=5
  )
  assert document.occurrences == 5
  assert len(document.contributions) == 3
  assert [item.event_id for item in document.contributions] == ["evt-0001", "evt-0004", "evt-0005"]
  assert document.event_ids == ["evt-0001", "evt-0002", "evt-0003", "evt-0004", "evt-0005"]
  assert document.first_seen == start + timedelta(seconds=1)
  assert document.last_seen == start + timedelta(seconds=5)
  assert "5 occurrences" in document.summary
