package com.example.observability.search.configuration;

import org.apache.http.HttpHost;
import org.opensearch.client.RestClient;
import org.opensearch.client.opensearch.OpenSearchClient;
import org.opensearch.client.transport.OpenSearchTransport;
import org.opensearch.client.transport.rest_client.RestClientTransport;
import org.opensearch.client.json.jackson.JacksonJsonpMapper;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenSearchConfiguration {
  @Bean
  RestClient restClient(QueryApiProperties properties) {
    return RestClient.builder(HttpHost.create(properties.opensearchUrl())).build();
  }

  @Bean
  OpenSearchClient openSearchClient(RestClient restClient) {
    OpenSearchTransport transport = new RestClientTransport(restClient, new JacksonJsonpMapper());
    return new OpenSearchClient(transport);
  }
}
