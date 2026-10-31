package com.example.observability.search.security;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.Jwt;

class JtiReplayValidatorTest {
  private final MutableClock clock = new MutableClock(Instant.parse("2026-07-01T10:00:00Z"));

  @Test
  void rejectsSecondUseOfTheSameJtiUntilExpiryAndAllowsAfterExpiry() {
    JtiReplayValidator validator = new JtiReplayValidator(clock, Duration.ofMinutes(15), 100, true);
    Jwt first = jwt("jti-1", "https://issuer.example", clock.instant().plusSeconds(60));

    assertThat(validator.validate(first).hasErrors()).isFalse();
    assertThat(validator.validate(first).hasErrors()).isTrue();

    clock.advance(Duration.ofSeconds(61));
    Jwt afterExpiry = jwt("jti-1", "https://issuer.example", clock.instant().plusSeconds(60));
    assertThat(validator.validate(afterExpiry).hasErrors()).isFalse();
    assertThat(validator.size()).isEqualTo(1);
  }

  @Test
  void scopesJtiCacheByIssuer() {
    JtiReplayValidator validator = new JtiReplayValidator(clock, Duration.ofMinutes(15), 100, true);
    Instant exp = clock.instant().plusSeconds(60);

    assertThat(validator.validate(jwt("shared-jti", "https://issuer-a.example", exp)).hasErrors()).isFalse();
    assertThat(validator.validate(jwt("shared-jti", "https://issuer-b.example", exp)).hasErrors()).isFalse();
    assertThat(validator.validate(jwt("shared-jti", "https://issuer-a.example", exp)).hasErrors()).isTrue();
  }

  @Test
  void rejectsMissingOrBlankJtiWhenRequired() {
    JtiReplayValidator validator = new JtiReplayValidator(clock, Duration.ofMinutes(15), 100, true);
    Instant exp = clock.instant().plusSeconds(60);

    assertThat(validator.validate(jwt(null, "https://issuer.example", exp)).hasErrors()).isTrue();
    assertThat(validator.validate(jwt("   ", "https://issuer.example", exp)).hasErrors()).isTrue();
  }

  @Test
  void allowsMissingJtiWhenOptionalButStillRejectsBlankOrReplayedJti() {
    JtiReplayValidator validator = new JtiReplayValidator(clock, Duration.ofMinutes(15), 100, false);
    Instant exp = clock.instant().plusSeconds(60);

    assertThat(validator.validate(jwt(null, "https://issuer.example", exp)).hasErrors()).isFalse();
    assertThat(validator.validate(jwt(null, "https://issuer.example", exp)).hasErrors()).isFalse();
    assertThat(validator.validate(jwt("", "https://issuer.example", exp)).hasErrors()).isTrue();

    Jwt withJti = jwt("dev-jti", "https://issuer.example", exp);
    assertThat(validator.validate(withJti).hasErrors()).isFalse();
    assertThat(validator.validate(withJti).hasErrors()).isTrue();
  }

  @Test
  void boundsCacheSizeByEvictingEarliestExpiringEntry() {
    JtiReplayValidator validator = new JtiReplayValidator(clock, Duration.ofMinutes(15), 2, true);
    Jwt earliest = jwt("jti-earliest", "https://issuer.example", clock.instant().plusSeconds(30));
    Jwt later = jwt("jti-later", "https://issuer.example", clock.instant().plusSeconds(120));
    Jwt newest = jwt("jti-newest", "https://issuer.example", clock.instant().plusSeconds(180));

    assertThat(validator.validate(earliest).hasErrors()).isFalse();
    assertThat(validator.validate(later).hasErrors()).isFalse();
    assertThat(validator.validate(newest).hasErrors()).isFalse();
    assertThat(validator.size()).isEqualTo(2);
    assertThat(validator.validate(later).hasErrors()).isTrue();
    assertThat(validator.validate(newest).hasErrors()).isTrue();
  }

  private Jwt jwt(String jti, String issuer, Instant expiresAt) {
    Jwt.Builder builder = Jwt.withTokenValue("token")
        .header("alg", "RS256")
        .claim("tenant", "trading")
        .issuedAt(clock.instant().minusSeconds(5))
        .expiresAt(expiresAt);
    if (jti != null) {
      builder.jti(jti);
    }
    if (issuer != null) {
      builder.issuer(issuer);
    }
    return builder.build();
  }

  private static final class MutableClock extends Clock {
    private Instant now;

    private MutableClock(Instant initial) {
      this.now = initial;
    }

    void advance(Duration duration) {
      this.now = this.now.plus(duration);
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return this;
    }

    @Override
    public Instant instant() {
      return now;
    }
  }
}

