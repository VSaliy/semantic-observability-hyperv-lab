package com.example.observability.search.security;

import java.nio.charset.StandardCharsets;
import javax.crypto.spec.SecretKeySpec;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtIssuerValidator;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

/**
 * Shared-secret HS256 validation for local development. It only exists under the {@code dev}
 * profile; every other profile must configure a standard resource-server issuer or JWKS URI.
 */
@Configuration
@Profile("dev")
class DevJwtConfiguration {
  private static final Logger LOGGER = LoggerFactory.getLogger(DevJwtConfiguration.class);
  private static final int MIN_SECRET_BYTES = 32;

  @Bean
  JwtDecoder devJwtDecoder(
      @Value("${query.jwt-secret:}") String secret,
      @Value("${query.jwt-issuer:}") String issuer,
      @Value("${query.allow-dev-auth:false}") boolean allowDevAuth,
      JtiReplayValidator jtiReplayValidator) {
    if (!allowDevAuth) {
      throw new IllegalStateException(
          "The 'dev' profile enables a public shared secret and must be opted into explicitly: set "
              + "query.allow-dev-auth=true. Never do this outside local development.");
    }
    if (secret.isBlank() || issuer.isBlank()) {
      throw new IllegalStateException(
          "The 'dev' profile requires query.jwt-secret and query.jwt-issuer (see application-dev.yaml).");
    }
    byte[] key = secret.getBytes(StandardCharsets.UTF_8);
    if (key.length < MIN_SECRET_BYTES) {
      throw new IllegalStateException("query.jwt-secret must be at least " + MIN_SECRET_BYTES + " bytes for HS256.");
    }
    LOGGER.warn("Profile 'dev' is active: accepting HS256 tokens signed with a shared development secret. "
        + "Do not use outside local development.");
    NimbusJwtDecoder decoder = NimbusJwtDecoder
        .withSecretKey(new SecretKeySpec(key, "HmacSHA256"))
        .build();
    OAuth2TokenValidator<Jwt> validator = new DelegatingOAuth2TokenValidator<>(
        JwtValidators.createDefault(),
        new JwtIssuerValidator(issuer),
        jtiReplayValidator);
    decoder.setJwtValidator(validator);
    return decoder;
  }
}
