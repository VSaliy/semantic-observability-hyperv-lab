package com.example.observability.search.configuration;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import java.time.Duration;
import java.time.format.DateTimeParseException;
import java.util.List;
import java.util.Map;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "query")
public record QueryApiProperties(
  @Min(1) int topKLimit,
  @NotBlank String defaultTimeRange,
  @NotBlank String maxTimeRange,
  @Min(1) int rateLimitPerMinute,
  @NotBlank String requiredTenantClaim,
  List<String> validEvidenceHosts,
  Map<String, List<String>> tenantValidEvidenceHosts,
  @NotBlank String embeddingUrl,
  @NotBlank String opensearchUrl,
  @NotBlank String opensearchIndexAlias,
  String referenceTime,
  @DecimalMin("-1.0") @DecimalMax("1.0") double minSemanticSimilarity
) {
  public QueryApiProperties {
    Duration parsedDefault = parsePositiveDuration("query.default-time-range", defaultTimeRange);
    Duration parsedMax = parsePositiveDuration("query.max-time-range", maxTimeRange);
    if (parsedDefault.compareTo(parsedMax) > 0) {
      throw new IllegalArgumentException(
        "query.default-time-range (" + parsedDefault + ") must not exceed query.max-time-range (" + parsedMax + ")"
      );
    }
  }

  public Duration defaultTimeRangeDuration() {
    return Duration.parse(defaultTimeRange);
  }

  public Duration maxTimeRangeDuration() {
    return Duration.parse(maxTimeRange);
  }

  private static Duration parsePositiveDuration(String propertyName, String rawValue) {
    if (rawValue == null || rawValue.isBlank()) {
      throw new IllegalArgumentException(propertyName + " must not be blank");
    }
    final Duration parsed;
    try {
      parsed = Duration.parse(rawValue);
    } catch (DateTimeParseException exception) {
      throw new IllegalArgumentException(propertyName + " is not a valid ISO-8601 duration: " + rawValue);
    }
    if (parsed.isZero() || parsed.isNegative()) {
      throw new IllegalArgumentException(propertyName + " must be positive: " + rawValue);
    }
    return parsed;
  }
}
