package com.example.observability.search.application;

import com.example.observability.search.configuration.QueryApiProperties;
import com.example.observability.search.domain.SearchMode;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.DistributionSummary;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;

@Service
public class TenantSearchService {
  private final QueryApiProperties properties;
  private final EmbeddingClient embeddingClient;
  private final SearchGateway searchGateway;
  private final DocumentScorer scorer;
  private final EvidencePolicy evidencePolicy;
  private final TenantRateLimiter rateLimiter;
  private final Clock clock;
  private final MeterRegistry meterRegistry;

  public TenantSearchService(QueryApiProperties properties, EmbeddingClient embeddingClient,
      SearchGateway searchGateway, DocumentScorer scorer, EvidencePolicy evidencePolicy,
      MeterRegistry meterRegistry, Clock clock) {
    this(properties, embeddingClient, searchGateway, scorer, evidencePolicy,
        new TenantRateLimiter(properties, meterRegistry), meterRegistry, clock);
  }

  @Autowired
  public TenantSearchService(QueryApiProperties properties, EmbeddingClient embeddingClient,
      SearchGateway searchGateway, DocumentScorer scorer, EvidencePolicy evidencePolicy,
      TenantRateLimiter rateLimiter, MeterRegistry meterRegistry, Clock clock) {
    this.properties = properties;
    this.embeddingClient = embeddingClient;
    this.searchGateway = searchGateway;
    this.scorer = scorer;
    this.evidencePolicy = evidencePolicy;
    this.rateLimiter = rateLimiter;
    this.meterRegistry = meterRegistry;
    this.clock = clock;
  }

  public SearchExecution search(String query, String environment, Duration timeRange, Integer requestedTopK,
      SearchMode mode, Jwt jwt) {
    String tenant = extractTenant(jwt);
    Duration effectiveRange = validateTimeRange(timeRange);
    rateLimiter.checkAllowed(tenant);
    int topK = Math.min(requestedTopK == null ? properties.topKLimit() : requestedTopK, properties.topKLimit());
    Instant to = clock.instant();
    Instant from = to.minus(effectiveRange);
    SearchCriteria criteria = new SearchCriteria(query, tenant, environment, from, to, topK, mode);
    Timer.Sample sample = Timer.start(meterRegistry);
    List<Float> embedding = mode == SearchMode.KEYWORD ? List.of() : embeddingClient.embed(query);
    List<SearchCandidate> keyword = mode == SearchMode.SEMANTIC ? List.of()
        : searchGateway.keywordSearch(criteria, topK * 2);
    List<SearchCandidate> semantic = mode == SearchMode.KEYWORD ? List.of()
        : searchGateway.semanticSearch(criteria, embedding, topK * 2);
    List<ScoredResult> results = scorer.score(criteria, keyword, semantic).stream()
        .map(result -> new ScoredResult(result.documentId(), result.type(), result.score(),
            result.explanation(), result.summary(), evidencePolicy.allowed(tenant, result.evidence())))
        .toList();
    sample.stop(meterRegistry.timer("query_api_latency", "mode", mode.name()));
    Counter.builder("query_api_zero_results_total").tag("mode", mode.name()).register(meterRegistry)
        .increment(results.isEmpty() ? 1 : 0);
    DistributionSummary.builder("query_api_result_count").tag("mode", mode.name())
        .register(meterRegistry).record(results.size());
    return new SearchExecution("qry-" + UUID.randomUUID().toString().substring(0, 8), criteria, results);
  }

  private String extractTenant(Jwt jwt) {
    String claim = jwt.getClaimAsString(properties.requiredTenantClaim());
    if (claim == null || claim.isBlank()) {
      throw new IllegalArgumentException("tenant claim is required");
    }
    return claim;
  }

  private Duration validateTimeRange(Duration requested) {
    Duration range = requested == null ? Duration.parse(properties.defaultTimeRange()) : requested;
    if (range.isZero() || range.isNegative()) {
      throw new IllegalArgumentException("timeRange must be positive");
    }
    String configuredMax = properties.maxTimeRange();
    Duration maxRange = (configuredMax == null || configuredMax.isBlank())
        ? Duration.ofHours(168)
        : Duration.parse(configuredMax);
    if (range.compareTo(maxRange) > 0) {
      throw new IllegalArgumentException("timeRange exceeds maximum allowed window of " + maxRange);
    }
    return range;
  }

  public record SearchExecution(String queryId, SearchCriteria criteria, List<ScoredResult> results) {}
}
