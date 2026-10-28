package com.example.observability.search.configuration;

import jakarta.validation.constraints.DecimalMax;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "query")
public record QueryApiProperties(
    @Min(1) int topKLimit,
    @NotBlank String defaultTimeRange,
    @NotBlank String jwtSecret,
    @NotBlank String jwtIssuer,
    @NotBlank String requiredTenantClaim,
    List<String> validEvidenceHosts,
    @NotBlank String embeddingUrl,
    @NotBlank String opensearchUrl,
    @NotBlank String opensearchIndexAlias,
    String referenceTime,
    @DecimalMin("-1.0") @DecimalMax("1.0") double minSemanticSimilarity) {}
