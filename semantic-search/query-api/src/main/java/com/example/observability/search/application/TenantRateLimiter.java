package com.example.observability.search.application;

import com.example.observability.search.configuration.QueryApiProperties;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

/**
 * Per-tenant sliding-window rate limiter for search requests. Uses the system clock by default so a
 * pinned {@code query.reference-time} in local development does not freeze the rate-limit window.
 */
@Component
public class TenantRateLimiter {
  private static final Duration WINDOW = Duration.ofMinutes(1);
  private static final int MAX_TRACKED_TENANTS = 1024;

  private final int maxRequestsPerMinute;
  private final Clock clock;
  private final Counter rateLimited;
  private final ConcurrentHashMap<String, Deque<Instant>> windows = new ConcurrentHashMap<>();

  @Autowired
  public TenantRateLimiter(QueryApiProperties properties, MeterRegistry meterRegistry) {
    this(properties.rateLimitPerMinute(), Clock.systemUTC(), meterRegistry);
  }

  TenantRateLimiter(int maxRequestsPerMinute, Clock clock, MeterRegistry meterRegistry) {
    if (maxRequestsPerMinute < 1) {
      throw new IllegalArgumentException("maxRequestsPerMinute must be at least 1");
    }
    this.maxRequestsPerMinute = maxRequestsPerMinute;
    this.clock = clock;
    this.rateLimited = Counter.builder("query_api_rate_limited_total").register(meterRegistry);
  }

  public void checkAllowed(String tenant) {
    Instant now = clock.instant();
    Instant cutoff = now.minus(WINDOW);
    Deque<Instant> timestamps = windows.computeIfAbsent(tenant, key -> {
      if (windows.size() >= MAX_TRACKED_TENANTS) {
        evictExpired(cutoff);
      }
      return new ArrayDeque<>();
    });
    synchronized (timestamps) {
      while (!timestamps.isEmpty() && !timestamps.peekFirst().isAfter(cutoff)) {
        timestamps.pollFirst();
      }
      if (timestamps.size() >= maxRequestsPerMinute) {
        rateLimited.increment();
        throw new TenantRateLimitExceededException(tenant);
      }
      timestamps.addLast(now);
    }
  }

  private void evictExpired(Instant cutoff) {
    Iterator<Map.Entry<String, Deque<Instant>>> iterator = windows.entrySet().iterator();
    while (iterator.hasNext()) {
      Map.Entry<String, Deque<Instant>> entry = iterator.next();
      Deque<Instant> deque = entry.getValue();
      synchronized (deque) {
        while (!deque.isEmpty() && !deque.peekFirst().isAfter(cutoff)) {
          deque.pollFirst();
        }
        if (deque.isEmpty()) {
          iterator.remove();
        }
      }
    }
  }
}

