package com.example.observability.search.security;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Rejects replayed JWTs by recording each seen {@code (issuer, jti)} pair in a bounded expiring
 * cache until the token's {@code exp} timestamp.
 */
public class JtiReplayValidator implements OAuth2TokenValidator<Jwt> {
  private static final Duration DEFAULT_TTL = Duration.ofMinutes(15);
  private static final int DEFAULT_MAX_ENTRIES = 10_000;

  private final Clock clock;
  private final Duration defaultTtl;
  private final int maxEntries;
  private final boolean requireJti;
  private final Map<String, Instant> seenUntil = new HashMap<>();

  public JtiReplayValidator(boolean requireJti) {
    this(Clock.systemUTC(), DEFAULT_TTL, DEFAULT_MAX_ENTRIES, requireJti);
  }

  JtiReplayValidator(Clock clock, Duration defaultTtl, int maxEntries, boolean requireJti) {
    this.clock = clock;
    this.defaultTtl = defaultTtl;
    this.maxEntries = maxEntries;
    this.requireJti = requireJti;
  }

  @Override
  public OAuth2TokenValidatorResult validate(Jwt token) {
    String jti = token.getId();
    if (jti == null) {
      if (requireJti) {
        return failure("The token must include a jti claim");
      }
      return OAuth2TokenValidatorResult.success();
    }
    if (jti.isBlank()) {
      return failure("The token jti claim must not be blank");
    }
    Instant now = clock.instant();
    Instant expiresAt = token.getExpiresAt() != null ? token.getExpiresAt() : now.plus(defaultTtl);
    if (!expiresAt.isAfter(now)) {
      return failure("The token has expired");
    }
    String issuer = token.getIssuer() != null ? token.getIssuer().toString() : "";
    String key = issuer + "\0" + jti;
    synchronized (seenUntil) {
      seenUntil.entrySet().removeIf(entry -> !entry.getValue().isAfter(now));
      if (seenUntil.containsKey(key)) {
        return failure("The token jti has already been used");
      }
      if (seenUntil.size() >= maxEntries) {
        seenUntil.entrySet().stream()
            .min(Comparator.comparing(Map.Entry::getValue))
            .map(Map.Entry::getKey)
            .ifPresent(seenUntil::remove);
      }
      seenUntil.put(key, expiresAt);
    }
    return OAuth2TokenValidatorResult.success();
  }

  int size() {
    synchronized (seenUntil) {
      return seenUntil.size();
    }
  }

  private static OAuth2TokenValidatorResult failure(String description) {
    return OAuth2TokenValidatorResult.failure(new OAuth2Error("invalid_token", description, null));
  }
}

