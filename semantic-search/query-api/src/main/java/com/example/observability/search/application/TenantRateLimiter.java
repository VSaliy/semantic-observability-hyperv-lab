package com.example.observability.search.application;

import com.example.observability.search.configuration.QueryApiProperties;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * Per-tenant sliding-window rate limiter. {@code softMaxTrackedTenants} is a soft cap: when reached,
 * expired tenant windows are swept outside any {@link ConcurrentHashMap} compute callback so active
 * tenants never lose their counters.
 */
@Component
public class TenantRateLimiter {
  private static final Duration WINDOW = Duration.ofMinutes(1);
  static final int DEFAULT_SOFT_MAX_TRACKED_TENANTS = 1024;

  private final int maxRequestsPerMinute;
  private final int softMaxTrackedTenants;
  private final Clock clock;
  private final Counter rateLimited;
  private final ConcurrentHashMap<String, Deque<Instant>> windows = new ConcurrentHashMap<>();

  @Autowired
  public TenantRateLimiter(QueryApiProperties properties, MeterRegistry meterRegistry) {
    this(properties.rateLimitPerMinute(), DEFAULT_SOFT_MAX_TRACKED_TENANTS, Clock.systemUTC(), meterRegistry);
  }

  TenantRateLimiter(int maxRequestsPerMinute, Clock clock, MeterRegistry meterRegistry) {
    this(maxRequestsPerMinute, DEFAULT_SOFT_MAX_TRACKED_TENANTS, clock, meterRegistry);
  }

  TenantRateLimiter(
    int maxRequestsPerMinute,
    int softMaxTrackedTenants,
    Clock clock,
    MeterRegistry meterRegistry
  ) {
    if (maxRequestsPerMinute < 1) {
      throw new IllegalArgumentException("maxRequestsPerMinute must be at least 1");
    }
    if (softMaxTrackedTenants < 1) {
      throw new IllegalArgumentException("softMaxTrackedTenants must be at least 1");
    }
    this.maxRequestsPerMinute = maxRequestsPerMinute;
    this.softMaxTrackedTenants = softMaxTrackedTenants;
    this.clock = clock;
    this.rateLimited = Counter.builder("query_api_rate_limited_total").register(meterRegistry);
  }

  public void checkAllowed(String tenant) {
    Instant now = clock.instant();
    Instant cutoff = now.minus(WINDOW);
    if (windows.size() >= softMaxTrackedTenants && !windows.containsKey(tenant)) {
      evictExpired(cutoff);
    }
    long[] retryAfterSeconds = new long[1];
    windows.compute(tenant, (key, existing) -> {
      Deque<Instant> timestamps = existing != null ? existing : new ArrayDeque<>();
      while (!timestamps.isEmpty() && !timestamps.peekFirst().isAfter(cutoff)) {
        timestamps.pollFirst();
      }
      if (timestamps.size() >= maxRequestsPerMinute) {
        Instant oldest = timestamps.peekFirst();
        long remainingNanos = oldest == null ? WINDOW.toNanos() : Duration.between(now, oldest.plus(WINDOW)).toNanos();
        retryAfterSeconds[0] = Math.max(1L, (remainingNanos + 999_999_999L) / 1_000_000_000L);
        return timestamps;
      }
      timestamps.addLast(now);
      return timestamps;
    });
    if (retryAfterSeconds[0] > 0) {
      rateLimited.increment();
      throw new TenantRateLimitExceededException(tenant, retryAfterSeconds[0]);
    }
  }

  private void evictExpired(Instant cutoff) {
    for (String trackedTenant : windows.keySet()) {
      windows.computeIfPresent(trackedTenant, (key, timestamps) -> {
        while (!timestamps.isEmpty() && !timestamps.peekFirst().isAfter(cutoff)) {
          timestamps.pollFirst();
        }
        return timestamps.isEmpty() ? null : timestamps;
      });
    }
  }
}
