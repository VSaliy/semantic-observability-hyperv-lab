package com.example.observability.search.api;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.application.DocumentScorer;
import com.example.observability.search.application.EmbeddingClient;
import com.example.observability.search.application.EvidencePolicy;
import com.example.observability.search.application.SearchCandidate;
import com.example.observability.search.application.SearchGateway;
import com.example.observability.search.application.TenantRateLimiter;
import com.example.observability.search.application.TenantSearchService;
import com.example.observability.search.configuration.ClockConfiguration;
import com.example.observability.search.configuration.QueryApiProperties;
import com.example.observability.search.domain.EvidenceLink;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

@WebMvcTest(SearchController.class)
@EnableConfigurationProperties(QueryApiProperties.class)
@Import({
  TestSecurityConfiguration.class,
  SimpleMeterRegistry.class,
  TenantSearchService.class,
  TenantRateLimiter.class,
  DocumentScorer.class,
  EvidencePolicy.class,
  ClockConfiguration.class
})
@TestPropertySource(properties = {
  "query.rate-limit-per-minute=2",
  "query.reference-time=2026-07-01T10:00:00Z"
})
class SearchControllerTest {
  @Autowired
  private MockMvc mockMvc;

  @MockitoBean
  private EmbeddingClient embeddingClient;

  @MockitoBean
  private SearchGateway searchGateway;

  @MockitoBean
  private JwtDecoder jwtDecoder;

  @Test
  void derivesTenantFromAuthentication() throws Exception {
    SearchCandidate candidate = new SearchCandidate(
      "doc-1",
      "incident",
      "trading",
      "production",
      Instant.parse("2026-07-01T09:50:00Z"),
      "risk-service",
      "CRITICAL",
      "CHG-0184",
      "Risk-service database pool exhaustion after CHG-0184.",
      "semantic text",
      List.of("risk-service", "trading"),
      List.of(new EvidenceLink("trace", "grafana", "https://grafana.example/tempo/trace-001")),
      8.5,
      "keyword"
    );
    when(embeddingClient.embed(any())).thenReturn(List.of(0.1f));
    when(searchGateway.keywordSearch(any(), anyInt())).thenReturn(List.of(candidate));
    when(searchGateway.semanticSearch(any(), any(), anyInt())).thenReturn(List.of());

    mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "trading").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content("""
          {
            "query": "slow requests",
            "environment": "production",
            "timeRange": "PT2H",
            "topK": 5,
            "mode": "HYBRID"
          }
          """))
      .andExpect(status().isOk())
      .andExpect(jsonPath("$.interpretedFilters.tenant").value("trading"))
      .andExpect(jsonPath("$.results[0].documentId").value("doc-1"));
  }

  @Test
  void rejectsUnknownTenantFieldInRequest() throws Exception {
    mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "trading").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content("""
          {
            "query": "slow requests",
            "tenantId": "other",
            "environment": "production",
            "timeRange": "PT2H",
            "topK": 5,
            "mode": "HYBRID"
          }
          """))
      .andExpect(status().isBadRequest());
  }

  @Test
  void enforcesSafeTopKLimit() throws Exception {
    mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "trading").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content("""
          {
            "query": "slow requests",
            "environment": "production",
            "timeRange": "PT2H",
            "topK": 99,
            "mode": "HYBRID"
          }
          """))
      .andExpect(status().isBadRequest());
  }

  @Test
  void rejectsMalformedTimeRangeAsBadRequest() throws Exception {
    mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "trading").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content("""
          {
            "query": "slow requests",
            "environment": "production",
            "timeRange": "2h",
            "topK": 5,
            "mode": "HYBRID"
          }
          """))
      .andExpect(status().isBadRequest())
      .andExpect(jsonPath("$.title").value("Invalid search request"));
  }

  @Test
  void returnsTooManyRequestsWithRetryAfterHeaderWhenRealTenantRateLimitIsExceeded() throws Exception {
    when(embeddingClient.embed(any())).thenReturn(List.of(0.1f));
    when(searchGateway.keywordSearch(any(), anyInt())).thenReturn(List.of());
    when(searchGateway.semanticSearch(any(), any(), anyInt())).thenReturn(List.of());

    String requestBody = """
      {
        "query": "slow requests",
        "environment": "production",
        "timeRange": "PT2H",
        "topK": 5,
        "mode": "HYBRID"
      }
      """;

    for (int i = 0; i < 2; i++) {
      mockMvc.perform(post("/api/v1/search")
          .with(jwt().jwt(jwt -> jwt.claim("tenant", "burst-tenant").issuer("http://localhost:8080/dev-issuer")))
          .contentType(MediaType.APPLICATION_JSON)
          .content(requestBody))
        .andExpect(status().isOk());
    }

    MvcResult limited = mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "burst-tenant").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content(requestBody))
      .andExpect(status().isTooManyRequests())
      .andExpect(header().exists(HttpHeaders.RETRY_AFTER))
      .andExpect(jsonPath("$.title").value("Rate limit exceeded"))
      .andReturn();

    long retryAfter = Long.parseLong(limited.getResponse().getHeader(HttpHeaders.RETRY_AFTER));
    assertThat(retryAfter).isBetween(1L, 60L);

    mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(jwt -> jwt.claim("tenant", "other-tenant").issuer("http://localhost:8080/dev-issuer")))
        .contentType(MediaType.APPLICATION_JSON)
        .content(requestBody))
      .andExpect(status().isOk());
  }
}
