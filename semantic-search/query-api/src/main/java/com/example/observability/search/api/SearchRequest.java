package com.example.observability.search.api;

import com.example.observability.search.domain.SearchMode;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

@JsonIgnoreProperties(ignoreUnknown = false)
public record SearchRequest(
    @NotBlank String query,
    @NotBlank String environment,
    @NotBlank String timeRange,
    @Min(1) @Max(20) Integer topK,
    @NotNull SearchMode mode) {}
