package com.example.observability.search.api;

import com.example.observability.search.domain.EvidenceLink;
import java.util.List;

public record SearchResponse(
    String queryId,
    InterpretedFilters interpretedFilters,
    List<ResultItem> results) {
  public record InterpretedFilters(String tenant, String environment, String from, String to) {}

  public record ResultItem(
      String documentId,
      String type,
      double score,
      List<String> explanation,
      String summary,
      List<EvidenceLink> evidence) {}
}
