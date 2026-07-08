package com.example.observability.search.infrastructure;

import com.example.observability.search.application.SearchCandidate;
import com.example.observability.search.application.SearchCriteria;
import com.example.observability.search.application.SearchGateway;
import com.example.observability.search.domain.EvidenceLink;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.InputStream;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;
import org.apache.http.entity.ContentType;
import org.apache.http.entity.StringEntity;
import org.opensearch.client.Request;
import org.opensearch.client.RestClient;
import org.springframework.stereotype.Component;

@Component
public class OpenSearchGateway implements SearchGateway {
  private final RestClient restClient;
  private final OpenSearchConnectionProperties properties;
  private final ObjectMapper objectMapper = new ObjectMapper();

  public OpenSearchGateway(RestClient restClient, OpenSearchConnectionProperties properties) {
    this.restClient = restClient;
    this.properties = properties;
  }

  @Override
  public List<SearchCandidate> keywordSearch(SearchCriteria criteria, int limit) {
    return execute(buildKeywordQuery(criteria, limit), "keyword");
  }

  @Override
  public List<SearchCandidate> semanticSearch(SearchCriteria criteria, List<Float> embedding, int limit) {
    return execute(buildSemanticQuery(criteria, embedding, limit), "semantic");
  }

  private String buildKeywordQuery(SearchCriteria criteria, int limit) {
    return """
        {
          "size": %d,
          "query": {
            "bool": {
              "filter": [
                {"term": {"tenant_id": %s}},
                {"term": {"environment": %s}},
                {"range": {"timestamp": {"gte": %s, "lte": %s}}}
              ],
              "must": [{
                "multi_match": {
                  "query": %s,
                  "fields": ["summary^3", "semantic_text^2", "service_name", "change_id", "document_type"]
                }
              }]
            }
          }
        }
        """.formatted(limit, json(criteria.tenantId()), json(criteria.environment()), json(criteria.from().toString()), json(criteria.to().toString()), json(criteria.query()));
  }

  private String buildSemanticQuery(SearchCriteria criteria, List<Float> embedding, int limit) {
    String vector = embedding.stream().map(String::valueOf).collect(Collectors.joining(","));
    return """
        {
          "size": %d,
          "query": {
            "script_score": {
              "query": {
                "bool": {
                  "filter": [
                    {"term": {"tenant_id": %s}},
                    {"term": {"environment": %s}},
                    {"range": {"timestamp": {"gte": %s, "lte": %s}}}
                  ]
                }
              },
              "script": {
                "source": "knn_score",
                "lang": "knn",
                "params": {
                  "field": "semantic_vector",
                  "query_value": [%s],
                  "space_type": "cosinesimil"
                }
              }
            }
          }
        }
        """.formatted(limit, json(criteria.tenantId()), json(criteria.environment()), json(criteria.from().toString()), json(criteria.to().toString()), vector);
  }

  private List<SearchCandidate> execute(String queryJson, String source) {
    try {
      Request request = new Request("POST", "/%s/_search".formatted(properties.opensearchIndexAlias()));
      request.setEntity(new StringEntity(queryJson, ContentType.APPLICATION_JSON));
      try (InputStream content = restClient.performRequest(request).getEntity().getContent()) {
        JsonNode hits = objectMapper.readTree(content).path("hits").path("hits");
        List<SearchCandidate> candidates = new ArrayList<>();
        for (JsonNode hit : hits) {
          JsonNode doc = hit.path("_source");
          candidates.add(new SearchCandidate(
              doc.path("document_id").asText(),
              doc.path("document_type").asText(),
              doc.path("tenant_id").asText(),
              doc.path("environment").asText(),
              Instant.parse(doc.path("timestamp").asText()),
              doc.path("service_name").asText(),
              doc.path("severity").asText(),
              doc.path("change_id").isMissingNode() || doc.path("change_id").isNull() ? null : doc.path("change_id").asText(),
              doc.path("summary").asText(),
              doc.path("semantic_text").asText(),
              toTextList(doc.path("topology_entities")),
              toEvidence(doc.path("source_references")),
              hit.path("_score").asDouble(),
              source));
        }
        return candidates;
      }
    } catch (IOException exception) {
      throw new IllegalStateException("OpenSearch query failed", exception);
    }
  }

  private List<String> toTextList(JsonNode node) {
    List<String> values = new ArrayList<>();
    for (JsonNode value : node) {
      values.add(value.asText());
    }
    return values;
  }

  private List<EvidenceLink> toEvidence(JsonNode node) {
    List<EvidenceLink> values = new ArrayList<>();
    for (JsonNode value : node) {
      values.add(new EvidenceLink(value.path("type").asText(), value.path("system").asText(), value.path("url").asText()));
    }
    return values;
  }

  private String json(String value) {
    try {
      return objectMapper.writeValueAsString(value);
    } catch (IOException exception) {
      throw new IllegalStateException(exception);
    }
  }
}
