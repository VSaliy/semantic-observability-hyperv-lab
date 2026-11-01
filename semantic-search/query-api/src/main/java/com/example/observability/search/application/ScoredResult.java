package com.example.observability.search.application;

import com.example.observability.search.domain.EvidenceLink;
import java.util.List;

public record ScoredResult(
    String documentId,
    String type,
    double score,
    List<String> explanation,
    String summary,
    List<EvidenceLink> evidence) {}
