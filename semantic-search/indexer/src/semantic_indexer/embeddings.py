from __future__ import annotations

import hashlib
from typing import Protocol

import httpx


class EmbeddingProvider(Protocol):
  def embed(self, text: str) -> list[float]: ...


class HttpEmbeddingProvider:
  def __init__(self, url: str, timeout_seconds: float) -> None:
    self._client = httpx.Client(base_url=url, timeout=timeout_seconds)

  def embed(self, text: str) -> list[float]:
    response = self._client.post("", json={"text": text})
    response.raise_for_status()
    payload = response.json()
    return [float(value) for value in payload["vector"]]


class DeterministicEmbeddingProvider:
  def embed(self, text: str) -> list[float]:
    digest = hashlib.sha256(text.encode("utf-8")).digest()
    return [round((byte / 255.0) * 2 - 1, 6) for byte in digest[:16]]
