from __future__ import annotations

import pytest

from semantic_indexer.documents import normalize_template
from semantic_indexer.embeddings import CachingEmbeddingProvider, DeterministicEmbeddingProvider


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
