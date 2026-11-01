package com.example.observability.search.application;

public class TenantRateLimitExceededException extends RuntimeException {
  public TenantRateLimitExceededException(String tenant) {
    super("rate limit exceeded for tenant " + tenant);
  }
}

