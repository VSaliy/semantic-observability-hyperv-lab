package com.example.observability.search.application;

import java.util.List;

public interface SearchGateway {
  List<SearchCandidate> keywordSearch(SearchCriteria criteria, int limit);

  List<SearchCandidate> semanticSearch(SearchCriteria criteria, List<Float> embedding, int limit);
}
