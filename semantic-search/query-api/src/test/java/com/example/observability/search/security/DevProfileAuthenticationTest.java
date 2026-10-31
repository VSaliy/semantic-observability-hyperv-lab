package com.example.observability.search.security;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.application.ScoredResult;
import com.example.observability.search.application.SearchCriteria;
import com.example.observability.search.application.TenantSearchService;
import com.example.observability.search.application.TenantSearchService.SearchExecution;
import com.example.observability.search.domain.SearchMode;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("dev")
class DevProfileAuthenticationTest {
  private static final String DEV_SECRET = "local-dev-secret-local-dev-secret";
  private static final String DEV_ISSUER = "http://localhost:8080/dev-issuer";

  @Autowired
  private MockMvc mockMvc;

  @MockitoBean
  private TenantSearchService tenantSearchService;

  @Test
  void validHs256TokenIsAcceptedUnderDevProfile() throws Exception {
    SearchCriteria criteria = new SearchCriteria("slow requests", "trading", "production",
        Instant.parse("2026-07-01T08:00:00Z"), Instant.parse("2026-07-01T10:00:00Z"), 5, SearchMode.HYBRID);
    when(tenantSearchService.search(eq("slow requests"), eq("production"), any(), eq(5), eq(SearchMode.HYBRID), any()))
        .thenReturn(new SearchExecution("qry-0001", criteria,
            List.of(new ScoredResult("doc-1", "incident", 0.9, List.of("semantic similarity"), "text", List.of()))));

    search(TestTokens.hs256(DEV_SECRET, DEV_ISSUER, "trading"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.interpretedFilters.tenant").value("trading"));
  }

  @Test
  void tokenSignedWithAnotherSecretIsRejected() throws Exception {
    search(TestTokens.hs256("another-secret-another-secret-123", DEV_ISSUER, "trading"))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void tokenFromAnotherIssuerIsRejected() throws Exception {
    search(TestTokens.hs256(DEV_SECRET, "http://evil.example/issuer", "trading"))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void missingTokenIsRejected() throws Exception {
    mockMvc.perform(post("/api/v1/search").contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isUnauthorized());
  }

  private ResultActions search(String token) throws Exception {
    return mockMvc.perform(post("/api/v1/search")
        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
        .contentType(MediaType.APPLICATION_JSON)
        .content("""
            {"query": "slow requests", "environment": "production", "timeRange": "PT2H", "topK": 5, "mode": "HYBRID"}
            """));
  }
}
