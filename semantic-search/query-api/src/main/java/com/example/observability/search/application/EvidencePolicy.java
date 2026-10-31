package com.example.observability.search.application;

import com.example.observability.search.configuration.QueryApiProperties;
import com.example.observability.search.domain.EvidenceLink;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.List;
import java.util.Set;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * Re-applies the indexer's evidence-host allowlist when results are returned, so a document that
 * was written by another path (or before the allowlist changed) cannot hand out foreign links.
 */
@Component
public class EvidencePolicy {
  private final Set<String> validHosts;
  private final Counter dropped;

  @Autowired
  public EvidencePolicy(QueryApiProperties properties, MeterRegistry meterRegistry) {
    this(properties.validEvidenceHosts(), meterRegistry);
  }

  EvidencePolicy(List<String> validHosts, MeterRegistry meterRegistry) {
    this.validHosts = Set.copyOf(validHosts);
    this.dropped = Counter.builder("query_api_evidence_links_dropped_total").register(meterRegistry);
  }

  public List<EvidenceLink> allowed(List<EvidenceLink> links) {
    List<EvidenceLink> kept = links.stream().filter(this::isAllowed).toList();
    dropped.increment(links.size() - kept.size());
    return kept;
  }

  boolean isAllowed(EvidenceLink link) {
    if (link == null || link.url() == null) {
      return false;
    }
    try {
      URI uri = new URI(link.url());
      String scheme = uri.getScheme();
      boolean httpScheme = "http".equals(scheme) || "https".equals(scheme);
      return httpScheme && uri.getRawAuthority() != null && validHosts.contains(uri.getRawAuthority());
    } catch (URISyntaxException exception) {
      return false;
    }
  }
}
