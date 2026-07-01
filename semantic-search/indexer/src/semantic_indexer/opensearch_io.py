from __future__ import annotations

from opensearchpy import OpenSearch

from semantic_indexer.models import SemanticDocument


class OpenSearchWriter:
  def __init__(self, url: str, index_alias: str) -> None:
    self._client = OpenSearch(url)
    self._index_alias = index_alias

  def write(self, document: SemanticDocument) -> None:
    self._client.index(
      index=self._index_alias,
      id=document.document_id,
      body=document.model_dump(mode="json")
    )
