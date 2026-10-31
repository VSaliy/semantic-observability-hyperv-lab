package com.example.observability.search.application;

import java.util.List;

public interface EmbeddingClient {
  List<Float> embed(String text);
}
