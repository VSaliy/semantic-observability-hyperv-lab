package com.example.observability.search.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
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
    clock.advance(Duration.ofSeconds(25));
    limiter.checkAllowed("trading");

    assertThatThrownBy(() -> limiter.checkAllowed("trading"))
      .isInstanceOf(TenantRateLimitExceededException.class)
      .satisfies(ex -> {
        TenantRateLimitExceededException rateEx = (TenantRateLimitExceededException) ex;
        assertThat(rateEx.retryAfterSeconds()).isEqualTo(35L);
      });
    assertThat(registry.get("query_api_rate_limited_total").counter().count()).isEqualTo(1.0);

    limiter.checkAllowed("market-data");

    clock.advance(Duration.ofSeconds(36));
    limiter.checkAllowed("trading");
  }

  @Test
  void concurrentRequestsAllowExactlyConfiguredLimit() throws Exception {
    MutableClock clock = new MutableClock(Instant.parse("2026-07-01T10:00:00Z"));
    SimpleMeterRegistry registry = new SimpleMeterRegistry();
    int limit = 5;
    int threads = 20;
    TenantRateLimiter limiter = new TenantRateLimiter(limit, clock, registry);

    CountDownLatch ready = new CountDownLatch(threads);
    CountDownLatch start = new CountDownLatch(1);
    AtomicInteger allowed = new AtomicInteger();
    AtomicInteger rejected = new AtomicInteger();

    ExecutorService pool = Executors.newFixedThreadPool(threads);
    try {
      List<Callable<Void>> tasks = new ArrayList<>();
      for (int i = 0; i < threads; i++) {
        tasks.add(() -> {
          ready.countDown();
          start.await();
          try {
            limiter.checkAllowed("trading");
            allowed.incrementAndGet();
          } catch (TenantRateLimitExceededException expected) {
            assertThat(expected.retryAfterSeconds()).isGreaterThanOrEqualTo(1L);
            rejected.incrementAndGet();
          }
          return null;
        });
      }
      List<Future<Void>> futures = new ArrayList<>();
      for (Callable<Void> task : tasks) {
        futures.add(pool.submit(task));
      }
      ready.await();
      start.countDown();
      for (Future<Void> future : futures) {
        future.get();
      }
    } finally {
      pool.shutdownNow();
    }

    assertThat(allowed.get()).isEqualTo(limit);
    assertThat(rejected.get()).isEqualTo(threads - limit);
    assertThat(registry.get("query_api_rate_limited_total").counter().count()).isEqualTo(threads - limit);
  }

  @Test
  void evictionDoesNotResetActiveTenantCount() {
    MutableClock clock = new MutableClock(Instant.parse("2026-07-01T10:00:00Z"));
    SimpleMeterRegistry registry = new SimpleMeterRegistry();
    TenantRateLimiter limiter = new TenantRateLimiter(2, 2, clock, registry);

    limiter.checkAllowed("stale-1");
    limiter.checkAllowed("stale-2");

    clock.advance(Duration.ofSeconds(40));
    limiter.checkAllowed("active");

    clock.advance(Duration.ofSeconds(21));
    limiter.checkAllowed("newcomer");

    limiter.checkAllowed("active");
    assertThatThrownBy(() -> limiter.checkAllowed("active"))
      .isInstanceOf(TenantRateLimitExceededException.class)
      .satisfies(ex -> {
        TenantRateLimitExceededException rateEx = (TenantRateLimitExceededException) ex;
        assertThat(rateEx.retryAfterSeconds()).isEqualTo(39L);
      });
  }
}
