package com.example.observability.search.api;

import static org.hamcrest.Matchers.hasSize;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.observability.search.SearchApplication;
import com.example.observability.search.application.EmbeddingClient;
import com.example.observability.search.domain.SearchMode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.containers.wait.strategy.Wait;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

/**
 * Proves tenant isolation against a real OpenSearch node using the production index template and
 * gateway queries. Only the embedding model is stubbed: it makes the other tenant's document the
 * best possible vector match, so an empty result can only come from the server-side tenant filter.
 */
@SpringBootTest(
    classes = {SearchApplication.class, TenantIsolationIntegrationTest.TestConfig.class},
    properties = {
        "query.reference-time=2026-07-01T11:30:00Z",
        "spring.security.oauth2.resourceserver.jwt.jwk-set-uri=http://127.0.0.1:1/unused-jwks"
    })
@AutoConfigureMockMvc
@Testcontainers(disabledWithoutDocker = true)
class TenantIsolationIntegrationTest {
  private static final String UNIQUE_PHRASE = "zebra-route-withdrawal";
  private static final String MARKET_DATA_DOCUMENT_ID = "market-data-network";
  private static final String INDEX = "observability-documents-v2";
  private static final String ALIAS = "observability-documents";
  private static final Path INDEX_TEMPLATE = Path.of("../schemas/opensearch/index-template.json");
  private static final HttpClient HTTP = HttpClient.newHttpClient();
  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static final List<Float> PHRASE_VECTOR = unitVector(0);
  private static final List<Float> OTHER_VECTOR = unitVector(1);

  @Container
  static final GenericContainer<?> OPENSEARCH =
      new GenericContainer<>(DockerImageName.parse("docker.io/opensearchproject/opensearch:2.17.0"))
          .withEnv("discovery.type", "single-node")
          .withEnv("DISABLE_SECURITY_PLUGIN", "true")
          .withEnv("OPENSEARCH_JAVA_OPTS", "-Xms512m -Xmx512m")
          .withExposedPorts(9200)
          .waitingFor(Wait.forHttp("/_cluster/health?wait_for_status=yellow").forStatusCode(200))
          .withStartupTimeout(Duration.ofMinutes(3));

  @Autowired
  private MockMvc mockMvc;

  @MockitoBean
  private JwtDecoder jwtDecoder;

  @DynamicPropertySource
  static void opensearchProperties(DynamicPropertyRegistry registry) {
    registry.add("query.opensearch-url", TenantIsolationIntegrationTest::opensearchUrl);
  }

  @BeforeAll
  static void seedIndex() throws Exception {
    send("PUT", "/_index_template/" + INDEX + "-template", Files.readString(INDEX_TEMPLATE));
    send("PUT", "/" + INDEX, "{}");
    // The query API reads through the alias, which init-opensearch.sh manages in deployments.
    send("PUT", "/" + INDEX + "/_alias/" + ALIAS, "{}");
    StringBuilder bulk = new StringBuilder();
    for (Map<String, Object> document : List.of(
        document("trading-incident", "trading", "incident", "2026-07-01T10:10:00Z",
            "Database pool exhaustion after CHG-0184.", OTHER_VECTOR),
        document("trading-log", "trading", "log_template", "2026-07-01T10:00:00Z",
            "Database connection acquisition timeout in risk-service.", OTHER_VECTOR),
        document(MARKET_DATA_DOCUMENT_ID, "market-data", "network_event", "2026-07-01T10:15:00Z",
            "Unique phrase " + UNIQUE_PHRASE + " occurred for market-data tenant only.", PHRASE_VECTOR))) {
      bulk.append(MAPPER.writeValueAsString(Map.of("index", Map.of("_index", INDEX, "_id", document.get("document_id")))))
          .append('\n')
          .append(MAPPER.writeValueAsString(document))
          .append('\n');
    }
    send("POST", "/_bulk?refresh=true", bulk.toString());
  }

  @ParameterizedTest
  @EnumSource(SearchMode.class)
  void uniquePhraseFromAnotherTenantReturnsZeroResults(SearchMode mode) throws Exception {
    search("trading", UNIQUE_PHRASE, mode)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.interpretedFilters.tenant").value("trading"))
        .andExpect(jsonPath("$.results").isEmpty());
  }

  @ParameterizedTest
  @EnumSource(SearchMode.class)
  void owningTenantFindsItsUniquePhrase(SearchMode mode) throws Exception {
    search("market-data", UNIQUE_PHRASE, mode)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.interpretedFilters.tenant").value("market-data"))
        .andExpect(jsonPath("$.results", hasSize(1)))
        .andExpect(jsonPath("$.results[0].documentId").value(MARKET_DATA_DOCUMENT_ID));
  }

  @Test
  void semanticMatchesAboveSimilarityFloorAreReturnedForOwnTenant() throws Exception {
    search("trading", "database connection timeout", SearchMode.SEMANTIC)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.results", hasSize(2)));
  }

  private ResultActions search(String tenant, String query, SearchMode mode) throws Exception {
    String body = MAPPER.writeValueAsString(Map.of(
        "query", query,
        "environment", "production",
        "timeRange", "PT2H",
        "topK", 5,
        "mode", mode.name()));
    return mockMvc.perform(post("/api/v1/search")
        .with(jwt().jwt(token -> token.claim("tenant", tenant)))
        .contentType(MediaType.APPLICATION_JSON)
        .content(body));
  }

  private static List<Float> unitVector(int axis) {
    List<Float> vector = new ArrayList<>(Collections.nCopies(16, 0.0f));
    vector.set(axis, 1.0f);
    return List.copyOf(vector);
  }

  private static Map<String, Object> document(String id, String tenant, String type, String timestamp,
      String summary, List<Float> vector) {
    return Map.of(
        "document_id", id,
        "document_type", type,
        "tenant_id", tenant,
        "environment", "production",
        "timestamp", timestamp,
        "service_name", tenant + "-service",
        "severity", "ERROR",
        "summary", summary,
        "semantic_text", summary,
        "semantic_vector", vector);
  }

  private static String opensearchUrl() {
    return "http://" + OPENSEARCH.getHost() + ":" + OPENSEARCH.getMappedPort(9200);
  }

  private static void send(String method, String path, String body) throws Exception {
    HttpRequest request = HttpRequest.newBuilder(URI.create(opensearchUrl() + path))
        .header("Content-Type", path.startsWith("/_bulk") ? "application/x-ndjson" : "application/json")
        .method(method, HttpRequest.BodyPublishers.ofString(body))
        .build();
    HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());
    if (response.statusCode() >= 300 || response.body().contains("\"errors\":true")) {
      throw new IllegalStateException(method + " " + path + " failed: " + response.body());
    }
  }

  @TestConfiguration
  static class TestConfig {
    @Bean
    @Primary
    EmbeddingClient embeddingClient() {
      return text -> text.contains(UNIQUE_PHRASE) ? PHRASE_VECTOR : OTHER_VECTOR;
    }
  }
}
