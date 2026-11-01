package com.example.observability.search.application;

public class TenantRateLimitExceededException extends RuntimeException {
  private final long retryAfterSeconds;

  public TenantRateLimitExceededException(String tenant, long retryAfterSeconds) {
    super("rate limit exceeded for tenant " + tenant);
    this.retryAfterSeconds = Math.max(1L, retryAfterSeconds);
  }

  public long retryAfterSeconds() {
    return retryAfterSeconds;
  }
}
