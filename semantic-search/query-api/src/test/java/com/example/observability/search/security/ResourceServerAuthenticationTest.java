package com.example.observability.search.security;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.application.ScoredResult;
import com.example.observability.search.application.SearchCriteria;
import com.example.observability.search.application.TenantSearchService;
import com.example.observability.search.application.TenantSearchService.SearchExecution;
import com.example.observability.search.domain.SearchMode;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.sun.net.httpserver.HttpServer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

/** Without the dev profile the API validates tokens against the configured JWKS only. */
@SpringBootTest
@AutoConfigureMockMvc
class ResourceServerAuthenticationTest {
  private static final RSAKey SIGNING_KEY;
  private static final HttpServer JWKS_SERVER;

  static {
    try {
      SIGNING_KEY = new RSAKeyGenerator(2048).keyID("test-key").generate();
      byte[] body = new JWKSet(SIGNING_KEY.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8);
      JWKS_SERVER = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
      JWKS_SERVER.createContext("/jwks", exchange -> {
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, body.length);
        exchange.getResponseBody().write(body);
        exchange.close();
      });
      JWKS_SERVER.start();
    } catch (Exception e) {
      throw new IllegalStateException("Could not start the JWKS stub", e);
    }
  }

  @Autowired
  private MockMvc mockMvc;

  @MockitoBean
  private TenantSearchService tenantSearchService;

  @DynamicPropertySource
  static void jwks(DynamicPropertyRegistry registry) {
    registry.add("spring.security.oauth2.resourceserver.jwt.jwk-set-uri",
        () -> "http://127.0.0.1:" + JWKS_SERVER.getAddress().getPort() + "/jwks");
  }

  @AfterAll
  static void stopJwksStub() {
    JWKS_SERVER.stop(0);
  }

  @Test
  void hs256TokenSignedWithTheDevSecretIsRejected() throws Exception {
    String forged = TestTokens.hs256("local-dev-secret-local-dev-secret", "http://localhost:8080/dev-issuer", "trading");
    search(forged).andExpect(status().isUnauthorized());
  }

  @Test
  void tokenSignedByTheConfiguredJwksIsAccepted() throws Exception {
    SearchCriteria criteria = new SearchCriteria("slow requests", "trading", "production",
        Instant.parse("2026-07-01T08:00:00Z"), Instant.parse("2026-07-01T10:00:00Z"), 5, SearchMode.HYBRID);
    when(tenantSearchService.search(eq("slow requests"), eq("production"), any(), eq(5), eq(SearchMode.HYBRID), any()))
        .thenReturn(new SearchExecution("qry-0001", criteria,
            List.of(new ScoredResult("doc-1", "incident", 0.9, List.of("semantic similarity"), "text", List.of()))));
    search(TestTokens.rs256(SIGNING_KEY, "trading")).andExpect(status().isOk());
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
