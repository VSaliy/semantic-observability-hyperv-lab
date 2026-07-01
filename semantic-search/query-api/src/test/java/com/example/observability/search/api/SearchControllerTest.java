package com.example.observability.search.api;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.application.ScoredResult;
import com.example.observability.search.application.SearchCriteria;
import com.example.observability.search.application.TenantSearchService;
import com.example.observability.search.application.TenantSearchService.SearchExecution;
import com.example.observability.search.domain.EvidenceLink;
import com.example.observability.search.domain.SearchMode;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.context.annotation.Import;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(SearchController.class)
@Import(TestSecurityConfiguration.class)
class SearchControllerTest {
  @Autowired
  private MockMvc mockMvc;

  @MockBean
  private TenantSearchService tenantSearchService;

  @MockBean
  private JwtDecoder jwtDecoder;

  @Test
  void derivesTenantFromAuthentication() throws Exception {
    SearchCriteria criteria = new SearchCriteria("slow requests", "trading", "production",
        Instant.parse("2026-07-01T08:00:00Z"), Instant.parse("2026-07-01T10:00:00Z"), 5, SearchMode.HYBRID);
    SearchExecution execution = new SearchExecution("qry-0001", criteria,
        List.of(new ScoredResult("doc-1", "incident", 0.91, List.of("semantic similarity"),
            "Risk-service database pool exhaustion after CHG-0184.",
            List.of(new EvidenceLink("trace", "grafana", "https://grafana.example/tempo/trace-001")))));
    when(tenantSearchService.search(eq("slow requests"), eq("production"), any(), eq(5), eq(SearchMode.HYBRID), any()))
        .thenReturn(execution);

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
}
