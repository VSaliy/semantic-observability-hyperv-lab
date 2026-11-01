package com.example.observability.search.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import org.junit.jupiter.api.Test;

class TenantRateLimiterTest {
  private static final class MutableClock extends Clock {
    private Instant now;

    MutableClock(Instant initial) {
      this.now = initial;
    }

    void advance(Duration duration) {
      this.now = this.now.plus(duration);
    }

    @Override
    public ZoneId getZone() {
      return ZoneId.of("UTC");
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

  @Test
  void enforcesPerTenantSlidingWindowAndIsolatesTenants() {
    MutableClock clock = new MutableClock(Instant.parse("2026-07-01T10:00:00Z"));
    SimpleMeterRegistry registry = new SimpleMeterRegistry();
    TenantRateLimiter limiter = new TenantRateLimiter(2, clock, registry);

    limiter.checkAllowed("trading");
    limiter.checkAllowed("trading");
    assertThatThrownBy(() -> limiter.checkAllowed("trading"))
        .isInstanceOf(TenantRateLimitExceededException.class)
        .hasMessageContaining("trading");
    assertThat(registry.get("query_api_rate_limited_total").counter().count()).isEqualTo(1.0);

    // Another tenant has its own independent budget.
    limiter.checkAllowed("market-data");

    // Advancing past the 1-minute window frees budget for the rate-limited tenant.
    clock.advance(Duration.ofSeconds(61));
    limiter.checkAllowed("trading");
  }
}

