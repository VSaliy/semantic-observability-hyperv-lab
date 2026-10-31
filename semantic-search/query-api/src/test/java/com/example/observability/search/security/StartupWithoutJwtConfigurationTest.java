package com.example.observability.search.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.example.observability.search.SearchApplication;
import org.junit.jupiter.api.Test;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;

class StartupWithoutJwtConfigurationTest {
  private static SpringApplicationBuilder application(String... properties) {
    return new SpringApplicationBuilder(SearchApplication.class)
        .web(WebApplicationType.SERVLET)
        .properties(properties);
  }

  @Test
  void failsWithoutDevProfileAndWithoutIssuerOrJwks() {
    assertThatThrownBy(() -> application("spring.profiles.active=none").run("--server.port=0"))
        .hasStackTraceContaining("No JWT validation is configured")
        .hasStackTraceContaining("issuer-uri");
  }

  @Test
  void sharedSecretPropertyAloneDoesNotEnableDevAuthentication() {
    assertThatThrownBy(() -> application(
        "spring.profiles.active=none",
        "query.jwt-secret=local-dev-secret-local-dev-secret").run("--server.port=0"))
        .hasStackTraceContaining("No JWT validation is configured");
  }

  @Test
  void startsWithDevProfile() {
    try (ConfigurableApplicationContext context = application("spring.profiles.active=dev").run("--server.port=0")) {
      assertThat(context.isRunning()).isTrue();
    }
  }
}
