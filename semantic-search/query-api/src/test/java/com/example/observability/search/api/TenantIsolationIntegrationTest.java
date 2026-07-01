package com.example.observability.search.api;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.SearchApplication;
import com.example.observability.search.application.EmbeddingClient;
import com.example.observability.search.application.SearchCandidate;
import com.example.observability.search.application.SearchCriteria;
import com.example.observability.search.application.SearchGateway;
import com.example.observability.search.domain.EvidenceLink;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(classes = {SearchApplication.class, TenantIsolationIntegrationTest.TestConfig.class})
@AutoConfigureMockMvc
class TenantIsolationIntegrationTest {
  @Autowired
  private MockMvc mockMvc;

  @MockBean
  private JwtDecoder jwtDecoder;

  @Test
  void uniquePhraseFromAnotherTenantReturnsZeroResults() throws Exception {
    mockMvc.perform(post("/api/v1/search")
            .with(jwt().jwt(jwt -> jwt.claim("tenant", "trading").issuer("http://localhost:8080/dev-issuer")))
            .contentType(MediaType.APPLICATION_JSON)
            .content("""
                {
                  "query": "zebra-route-withdrawal",
                  "environment": "production",
                  "timeRange": "PT2H",
                  "topK": 5,
                  "mode": "HYBRID"
                }
                """))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.interpretedFilters.tenant").value("trading"))
        .andExpect(jsonPath("$.results").isEmpty());
  }

  @TestConfiguration
  static class TestConfig {
    @Bean
    @Primary
    EmbeddingClient embeddingClient() {
      return text -> List.of(0.1f, 0.2f, 0.3f);
    }

    @Bean
    @Primary
    SearchGateway searchGateway() {
      List<SearchCandidate> dataset = List.of(
          new SearchCandidate("trading-incident", "incident", "trading", "production",
              Instant.parse("2026-07-01T10:10:00Z"), "risk-service", "CRITICAL", "CHG-0184",
              "Database pool exhaustion after CHG-0184.", "Trade requests failed after a deployment.",
              List.of("risk-service", "trade-api"), List.of(new EvidenceLink("trace", "grafana", "https://grafana.example/tempo/trace-001")), 4.5,
              "keyword"),
          new SearchCandidate("market-data-network", "network_event", "market-data", "production",
              Instant.parse("2026-07-01T10:15:00Z"), "market-data-api", "ERROR", "CHG-0200",
              "Unique phrase zebra-route-withdrawal occurred for market-data tenant only.", "Network route withdrawal.",
              List.of("market-data-api"), List.of(new EvidenceLink("network", "grafana", "https://grafana.example/network/route-zebra")), 4.9,
              "keyword"));
      return new SearchGateway() {
        @Override
        public List<SearchCandidate> keywordSearch(SearchCriteria criteria, int limit) {
          return filter(criteria, dataset, limit);
        }

        @Override
        public List<SearchCandidate> semanticSearch(SearchCriteria criteria, List<Float> embedding, int limit) {
          return filter(criteria, dataset, limit);
        }

        private List<SearchCandidate> filter(SearchCriteria criteria, List<SearchCandidate> candidates, int limit) {
          String query = criteria.query().toLowerCase(Locale.ROOT);
          return candidates.stream()
              .filter(candidate -> candidate.tenantId().equals(criteria.tenantId()))
              .filter(candidate -> candidate.environment().equals(criteria.environment()))
              .filter(candidate -> !candidate.timestamp().isBefore(criteria.from()) && !candidate.timestamp().isAfter(criteria.to()))
              .filter(candidate -> candidate.summary().toLowerCase(Locale.ROOT).contains(query)
                  || candidate.semanticText().toLowerCase(Locale.ROOT).contains(query))
              .limit(limit)
              .toList();
        }
      };
    }
  }
}
