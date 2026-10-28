package com.example.observability.search.configuration;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class ClockConfiguration {
  // A fixed reference time lets the deterministic seed fixtures fall inside relative search windows.
  // Intended for local development only; leave unset everywhere else to use the system clock.
  @Bean
  Clock clock(QueryApiProperties properties) {
    String referenceTime = properties.referenceTime();
    if (referenceTime == null || referenceTime.isBlank()) {
      return Clock.systemUTC();
    }
    return Clock.fixed(Instant.parse(referenceTime), ZoneOffset.UTC);
  }
}
