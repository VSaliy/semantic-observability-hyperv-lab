from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel, Field

from semantic_indexer.embeddings import DeterministicEmbeddingProvider

app = FastAPI(title="deterministic-embedding-service")
provider = DeterministicEmbeddingProvider()


class EmbeddingRequest(BaseModel):
  text: str = Field(min_length=1, max_length=4000)


@app.post("/embed")
def embed(request: EmbeddingRequest) -> dict[str, list[float]]:
  return {"vector": provider.embed(request.text)}
