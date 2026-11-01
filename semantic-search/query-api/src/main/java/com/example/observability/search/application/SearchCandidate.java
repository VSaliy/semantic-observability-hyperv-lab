package com.example.observability.search.application;

import com.example.observability.search.domain.EvidenceLink;
import java.time.Instant;
import java.util.List;

public record SearchCandidate(
    String documentId,
    String documentType,
    String tenantId,
    String environment,
    Instant timestamp,
    String serviceName,
    String severity,
    String changeId,
    String summary,
    String semanticText,
    List<String> topologyEntities,
    List<EvidenceLink> evidence,
    double baseScore,
    String source) {}
