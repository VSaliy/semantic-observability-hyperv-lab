package com.example.observability.search.application;

import com.example.observability.search.domain.SearchMode;
import java.time.Instant;

public record SearchCriteria(
    String query,
    String tenantId,
    String environment,
    Instant from,
    Instant to,
    int topK,
    SearchMode mode) {}
