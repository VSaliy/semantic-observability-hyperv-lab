package com.example.observability.search.application;

import com.example.observability.search.configuration.QueryApiProperties;
import com.example.observability.search.domain.EvidenceLink;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * Re-applies the indexer's per-tenant evidence-host allowlist when results are returned, so a
 * document that was written by another path (or before the allowlist changed) cannot hand out
 * foreign links.
 */
@Component
public class EvidencePolicy {
  private final Set<String> validHosts;
  private final Map<String, Set<String>> tenantValidHosts;
  private final Counter dropped;

  @Autowired
  public EvidencePolicy(QueryApiProperties properties, MeterRegistry meterRegistry) {
    this(
        properties.validEvidenceHosts(),
        properties.tenantValidEvidenceHosts(),
        meterRegistry);
  }

  EvidencePolicy(List<String> validHosts, MeterRegistry meterRegistry) {
    this(validHosts, Map.of(), meterRegistry);
  }

  EvidencePolicy(
      List<String> validHosts,
      Map<String, List<String>> tenantValidHosts,
      MeterRegistry meterRegistry) {
    this.validHosts = validHosts == null ? Set.of() : Set.copyOf(validHosts);
    this.tenantValidHosts =
        tenantValidHosts == null
            ? Map.of()
            : tenantValidHosts.entrySet().stream()
                .collect(Collectors.toUnmodifiableMap(Map.Entry::getKey, e -> Set.copyOf(e.getValue())));
    this.dropped = Counter.builder("query_api_evidence_links_dropped_total").register(meterRegistry);
  }

  public List<EvidenceLink> allowed(List<EvidenceLink> links) {
    return allowed(null, links);
  }

  public List<EvidenceLink> allowed(String tenant, List<EvidenceLink> links) {
    Set<String> allowedHosts =
        tenant != null && tenantValidHosts.containsKey(tenant)
            ? tenantValidHosts.get(tenant)
            : validHosts;
    List<EvidenceLink> kept =
        links.stream().filter(link -> isAllowed(link, allowedHosts)).toList();
    dropped.increment(links.size() - kept.size());
    return kept;
  }

  boolean isAllowed(EvidenceLink link) {
    return isAllowed(link, validHosts);
  }

  private static boolean isAllowed(EvidenceLink link, Set<String> allowedHosts) {
    if (link == null || link.url() == null) {
      return false;
    }
    try {
      URI uri = new URI(link.url());
      String scheme = uri.getScheme();
      boolean httpScheme = "http".equals(scheme) || "https".equals(scheme);
      return httpScheme && uri.getRawAuthority() != null && allowedHosts.contains(uri.getRawAuthority());
    } catch (URISyntaxException exception) {
      return false;
    }
  }
}
