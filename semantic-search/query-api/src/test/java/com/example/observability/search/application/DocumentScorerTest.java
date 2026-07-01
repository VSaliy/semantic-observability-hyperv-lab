package com.example.observability.search.application;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.observability.search.domain.EvidenceLink;
import com.example.observability.search.domain.SearchMode;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;

class DocumentScorerTest {
  private final DocumentScorer scorer = new DocumentScorer();

  @Test
  void hybridModePrefersIncidentAlignedWithChangeAndService() {
    SearchCriteria criteria = new SearchCriteria("Why are trade requests slow after the latest deployment?",
        "trading", "production", Instant.parse("2026-07-01T08:00:00Z"), Instant.parse("2026-07-01T10:30:00Z"), 5,
        SearchMode.HYBRID);
    SearchCandidate candidate = new SearchCandidate("1", "incident", "trading", "production",
        Instant.parse("2026-07-01T10:10:00Z"), "trade-api", "CRITICAL", "CHG-0184",
        "Risk-service database pool exhaustion after CHG-0184.", "semantic text",
        List.of("trade-api", "risk-service"), List.of(new EvidenceLink("trace", "grafana", "https://grafana.example/tempo")), 4.9,
        "keyword");
    List<ScoredResult> results = scorer.score(criteria, List.of(candidate), List.of(candidate));
    assertThat(results.getFirst().documentId()).isEqualTo("1");
    assertThat(results.getFirst().explanation()).contains("keyword relevance", "semantic similarity", "same change");
  }
}
