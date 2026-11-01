from __future__ import annotations

import hashlib
from collections import OrderedDict
from typing import Protocol

import httpx


class EmbeddingProvider(Protocol):
  def embed(self, text: str) -> list[float]: ...


class HttpEmbeddingProvider:
  def __init__(self, url: str, timeout_seconds: float) -> None:
    self._url = url
    self._client = httpx.Client(timeout=timeout_seconds)

  def embed(self, text: str) -> list[float]:
    response = self._client.post(self._url, json={"text": text})
    response.raise_for_status()
    payload = response.json()
    return [float(value) for value in payload["vector"]]


class DeterministicEmbeddingProvider:
  def embed(self, text: str) -> list[float]:
    digest = hashlib.sha256(text.encode("utf-8")).digest()
    return [round((byte / 255.0) * 2 - 1, 6) for byte in digest[:16]]


class CachingEmbeddingProvider:
  """Bounded LRU cache so repeated aggregate text is embedded once, not once per event."""

  def __init__(self, delegate: EmbeddingProvider, max_entries: int = 1024) -> None:
    if max_entries < 1:
      raise ValueError("max_entries must be positive")
    self._delegate = delegate
    self._max_entries = max_entries
    self._cache: OrderedDict[str, list[float]] = OrderedDict()

  def embed(self, text: str) -> list[float]:
    cached = self._cache.get(text)
    if cached is not None:
      self._cache.move_to_end(text)
      return list(cached)
    vector = self._delegate.embed(text)
    self._cache[text] = list(vector)
    if len(self._cache) > self._max_entries:
      self._cache.popitem(last=False)
    return vector
