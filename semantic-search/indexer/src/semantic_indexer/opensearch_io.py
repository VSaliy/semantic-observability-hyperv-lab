from __future__ import annotations

from typing import cast

from opensearchpy import ConflictError, NotFoundError, OpenSearch

from semantic_indexer.models import SemanticDocument
from semantic_indexer.service import StoredDocument


class OpenSearchDocumentStore:
  """Aggregate store using optimistic concurrency (if_seq_no / if_primary_term)."""

  def __init__(self, url: str, index_alias: str, client: OpenSearch | None = None) -> None:
    self._client = client or OpenSearch(url)
    self._index_alias = index_alias

  def get(self, document_id: str) -> StoredDocument | None:
    try:
      response = self._client.get(index=self._index_alias, id=document_id)
    except NotFoundError:
      return None
    return StoredDocument(
      document=SemanticDocument.model_validate(response["_source"]),
      version=(response["_seq_no"], response["_primary_term"])
    )

  def put(self, document: SemanticDocument, expected: StoredDocument | None) -> bool:
    body = document.model_dump(mode="json")
    try:
      if expected is None:
        self._client.index(
          index=self._index_alias, id=document.document_id, body=body, op_type="create"
        )
      else:
        seq_no, primary_term = cast(tuple[int, int], expected.version)
        self._client.index(
          index=self._index_alias,
          id=document.document_id,
          body=body,
          if_seq_no=seq_no,
          if_primary_term=primary_term
        )
    except ConflictError:
      return False
    return True
