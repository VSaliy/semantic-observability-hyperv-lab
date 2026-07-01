package com.example.observability.search.infrastructure;

import com.example.observability.search.application.EmbeddingClient;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import org.springframework.stereotype.Component;

@Component
public class HttpEmbeddingClient implements EmbeddingClient {
  private final HttpClient httpClient = HttpClient.newHttpClient();
  private final ObjectMapper objectMapper = new ObjectMapper();
  private final OpenSearchConnectionProperties properties;

  public HttpEmbeddingClient(OpenSearchConnectionProperties properties) {
    this.properties = properties;
  }

  @Override
  public List<Float> embed(String text) {
    try {
      String requestBody = objectMapper.writeValueAsString(new EmbedRequest(text));
      HttpRequest request = HttpRequest.newBuilder(URI.create(properties.embeddingUrl()))
          .timeout(Duration.ofSeconds(5))
          .header("Content-Type", "application/json")
          .POST(HttpRequest.BodyPublishers.ofString(requestBody))
          .build();
      HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
      if (response.statusCode() >= 400) {
        throw new IllegalStateException("embedding request failed with status " + response.statusCode());
      }
      JsonNode node = objectMapper.readTree(response.body()).path("vector");
      List<Float> vector = new ArrayList<>();
      for (JsonNode value : node) {
        vector.add(value.floatValue());
      }
      return vector;
    } catch (InterruptedException exception) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("embedding request failed", exception);
    } catch (IOException exception) {
      throw new IllegalStateException("embedding request failed", exception);
    }
  }

  private record EmbedRequest(String text) {}
}
