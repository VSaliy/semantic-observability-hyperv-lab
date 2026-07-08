package com.example.observability.search.infrastructure;

import com.example.observability.search.configuration.QueryApiProperties;
import org.springframework.stereotype.Component;

@Component
public class OpenSearchConnectionProperties {
  private final QueryApiProperties properties;

  public OpenSearchConnectionProperties(QueryApiProperties properties) {
    this.properties = properties;
  }

  public String opensearchUrl() {
    return properties.opensearchUrl();
  }

  public String opensearchIndexAlias() {
    return properties.opensearchIndexAlias();
  }

  public String embeddingUrl() {
    return properties.embeddingUrl();
  }
}
