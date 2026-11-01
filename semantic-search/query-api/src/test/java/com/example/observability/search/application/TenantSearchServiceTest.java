package com.example.observability.search.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.example.observability.search.configuration.QueryApiProperties;
import com.example.observability.search.domain.SearchMode;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;

class TenantSearchServiceTest {
  private static TenantSearchService buildService(int rateLimitPerMinute) {
    QueryApiProperties properties = new QueryApiProperties(
        20,
        "PT2H",
        "PT168H",
        rateLimitPerMinute,
        "tenant",
        List.of("grafana.example"),
        Map.of(),
        "http://embedding-service:8090/embed",
        "http://opensearch:9200",
        "observability-documents",
        "2026-07-01T11:30:00Z",
        0.5);
    SimpleMeterRegistry registry = new SimpleMeterRegistry();
    Clock clock = Clock.fixed(Instant.parse("2026-07-01T11:30:00Z"), ZoneOffset.UTC);
    SearchGateway gateway = new SearchGateway() {
      @Override
      public List<SearchCandidate> keywordSearch(SearchCriteria criteria, int size) {
        return List.of();
      }

      @Override
      public List<SearchCandidate> semanticSearch(SearchCriteria criteria, List<Float> vector, int size) {
        return List.of();
      }
    };
    return new TenantSearchService(
        properties,
        text -> List.of(0.1f),
        gateway,
        new DocumentScorer(),
        new EvidencePolicy(properties, registry),
        new TenantRateLimiter(rateLimitPerMinute, clock, registry),
        registry,
        clock);
  }

  private static Jwt jwtFor(String tenant) {
    return Jwt.withTokenValue("token")
        .header("alg", "none")
        .claim("tenant", tenant)
        .build();
  }

  @Test
  void rejectsZeroNegativeAndExcessiveTimeRanges() {
    TenantSearchService service = buildService(10);
    Jwt jwt = jwtFor("trading");

    assertThatThrownBy(() -> service.search("q", "production", Duration.ZERO, 5, SearchMode.KEYWORD, jwt))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("timeRange must be positive");

    assertThatThrownBy(() -> service.search("q", "production", Duration.ofHours(-2), 5, SearchMode.KEYWORD, jwt))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("timeRange must be positive");

    assertThatThrownBy(() -> service.search("q", "production", Duration.ofHours(200), 5, SearchMode.KEYWORD, jwt))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessageContaining("timeRange exceeds maximum allowed window");
  }

  @Test
  void enforcesPerTenantRateLimitInSearchService() {
    TenantSearchService service = buildService(1);
    Jwt trading = jwtFor("trading");

    service.search("q", "production", Duration.ofHours(2), 5, SearchMode.KEYWORD, trading);
    assertThatThrownBy(() -> service.search("q", "production", Duration.ofHours(2), 5, SearchMode.KEYWORD, trading))
        .isInstanceOf(TenantRateLimitExceededException.class);
  }
}

