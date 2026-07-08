package com.example.observability.search.application;

import com.example.observability.search.domain.SearchMode;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

import org.springframework.stereotype.Component;

@Component
public class DocumentScorer {
  public List<ScoredResult> score(SearchCriteria criteria, List<SearchCandidate> keywordCandidates,
      List<SearchCandidate> semanticCandidates) {
    Map<String, Aggregate> aggregateById = new HashMap<>();
    mergeCandidates(aggregateById, keywordCandidates, "keyword");
    mergeCandidates(aggregateById, semanticCandidates, "semantic");
    return aggregateById.values().stream()
        .map(aggregate -> toScoredResult(criteria, aggregate))
        .sorted(Comparator.comparingDouble(ScoredResult::score).reversed())
        .limit(criteria.topK())
        .toList();
  }

  private void mergeCandidates(Map<String, Aggregate> aggregateById, List<SearchCandidate> candidates,
      String source) {
    for (SearchCandidate candidate : candidates) {
      aggregateById.computeIfAbsent(candidate.documentId(), ignored -> new Aggregate(candidate))
          .apply(candidate, source);
    }
  }

  private ScoredResult toScoredResult(SearchCriteria criteria, Aggregate aggregate) {
    SearchCandidate candidate = aggregate.primary;
    double keywordScore = normalize(aggregate.keywordScore);
    double semanticScore = normalize(aggregate.semanticScore);
    double timeScore = timeProximity(candidate.timestamp(), criteria.from(), criteria.to());
    double serviceScore = containsToken(criteria.query(), candidate.serviceName()) ? 1.0 : 0.0;
    double topologyScore = candidate.topologyEntities().stream().anyMatch(entity -> containsToken(criteria.query(), entity)) ? 1.0 : 0.0;
    double severityScore = switch (candidate.severity()) {
      case "CRITICAL" -> 1.0;
      case "ERROR" -> 0.8;
      case "WARN" -> 0.5;
      default -> 0.2;
    };
    double changeScore = containsToken(criteria.query(), "deployment") || containsToken(criteria.query(), "change") || containsToken(criteria.query(), "latest")
        ? candidate.changeId() == null ? 0.0 : 1.0
        : 0.0;
    double total = (keywordScore * 0.40) + (semanticScore * 0.35) + (timeScore * 0.10)
        + (serviceScore * 0.05) + (topologyScore * 0.03) + (severityScore * 0.04) + (changeScore * 0.03);
    List<String> explanation = new ArrayList<>();
    SearchMode mode = criteria.mode();
    if (mode != SearchMode.SEMANTIC && keywordScore > 0.0) {
      explanation.add("keyword relevance");
    }
    if (mode != SearchMode.KEYWORD && semanticScore > 0.0) {
      explanation.add("semantic similarity");
    }
    if (timeScore > 0.0) {
      explanation.add("within time window");
    }
    if (serviceScore > 0.0) {
      explanation.add("same service");
    }
    if (changeScore > 0.0) {
      explanation.add("same change");
    }
    if (topologyScore > 0.0) {
      explanation.add("topology proximity");
    }
    return new ScoredResult(candidate.documentId(), candidate.documentType(), round(total), explanation,
        candidate.summary(), candidate.evidence());
  }

  private boolean containsToken(String query, String value) {
    if (query == null || query.isBlank() || value == null || value.isBlank()) {
      return false;
    }
    return query.toLowerCase(Locale.ROOT).contains(value.toLowerCase(Locale.ROOT));
  }

  private double normalize(double score) {
    if (score <= 0) {
      return 0.0;
    }
    return Math.min(score / 5.0, 1.0);
  }

  private double timeProximity(Instant timestamp, Instant from, Instant to) {
    long totalWindow = Duration.between(from, to).toSeconds();
    if (totalWindow <= 0) {
      return 0.0;
    }
    long distance = Math.abs(Duration.between(timestamp, to).toSeconds());
    return Math.max(0.0, 1.0 - ((double) distance / totalWindow));
  }

  private double round(double value) {
    return Math.round(value * 100.0) / 100.0;
  }

  private static final class Aggregate {
    private final SearchCandidate primary;
    private double keywordScore;
    private double semanticScore;
    private final Set<String> seenSources = new LinkedHashSet<>();

    private Aggregate(SearchCandidate primary) {
      this.primary = primary;
    }

    private void apply(SearchCandidate candidate, String source) {
      seenSources.add(source);
      if ("keyword".equals(source)) {
        keywordScore = Math.max(keywordScore, candidate.baseScore());
      }
      if ("semantic".equals(source)) {
        semanticScore = Math.max(semanticScore, candidate.baseScore());
      }
    }
  }
}
