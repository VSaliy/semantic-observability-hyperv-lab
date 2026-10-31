package com.example.observability.search.application;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.observability.search.domain.EvidenceLink;
import java.util.List;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.junit.jupiter.api.Test;

class EvidencePolicyTest {
  private final EvidencePolicy policy = new EvidencePolicy(List.of("grafana.example", "kafka.example"));

  private static EvidenceLink link(String url) {
    return new EvidenceLink("log", "grafana", url);
  }

  @Test
  void keepsAllowlistedHttpAndHttpsLinks() {
    List<EvidenceLink> links = List.of(link("https://grafana.example/d/abc?x=1"), link("http://kafka.example/t"));
    assertThat(policy.allowed(links)).isEqualTo(links);
  }

  @ParameterizedTest
  @ValueSource(strings = {
      "javascript:alert(1)",
      "ftp://grafana.example/x",
      "file:///etc/passwd",
      "//grafana.example/x",
      "/relative/path",
      "https://grafana.example.evil.test/x",
      "https://evil.test/grafana.example",
      "https://grafana.example@evil.test/x",
      "https://evil.test@grafana.example/x",
      "https://grafana.example:8443/x",
      "https://GRAFANA.example/x",
      "https://grafana.example/has space",
      ""
  })
  void dropsEverythingOutsideTheAllowlist(String url) {
    assertThat(policy.allowed(List.of(link(url)))).isEmpty();
  }

  @Test
  void dropsNullUrlsAndKeepsTheRest() {
    EvidenceLink good = link("https://grafana.example/d/1");
    assertThat(policy.allowed(List.of(link(null), link("https://evil.test/x"), good))).containsExactly(good);
  }
}
